#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A variable set over the inherited environment. Bytes, not String: a login
/// shell's environment need not be UTF-8.
public struct EnvVar: Sendable, Equatable {
  public var name: [UInt8]
  public var value: [UInt8]

  public init(_ name: [UInt8], _ value: [UInt8]) {
    self.name = name
    self.value = value
  }
}

struct Output: Sendable {
  /// nil when a signal ended the process.
  var status: Int32?
  var stdout: [UInt8]
  var stderr: [UInt8]

  var success: Bool { status == 0 }
}

/// Runs `program` with `args` and returns its output. The deadline covers
/// reading output too: a descendant that inherits a pipe can hold it open
/// after the child exits. The child runs in its own process group so a
/// timeout stops every process it started.
func capture(
  _ program: String, _ args: [String], overlay: [EnvVar] = [], timeout: Duration
) throws(GhError) -> Output {
  let env = merged(overlay)
  guard let path = resolve(program, env: env) else { throw .notInstalled }

  var out: [Int32] = [0, 0]
  var err: [Int32] = [0, 0]
  guard pipe(&out) == 0 else { throw .spawn(errorText(errno)) }
  guard pipe(&err) == 0 else {
    close(out[0])
    close(out[1])
    throw .spawn(errorText(errno))
  }
  #if !canImport(Darwin)
    // Darwin uses POSIX_SPAWN_CLOEXEC_DEFAULT below; Glibc's pipe2 isn't
    // imported, and only the tests run on Linux.
    for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
  #endif

  #if canImport(Darwin)
    var actions: posix_spawn_file_actions_t? = nil
    var attr: posix_spawnattr_t? = nil
  #else
    var actions = posix_spawn_file_actions_t()
    var attr = posix_spawnattr_t()
  #endif
  posix_spawn_file_actions_init(&actions)
  posix_spawnattr_init(&attr)
  defer {
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
  }
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_adddup2(&actions, out[1], 1)
  posix_spawn_file_actions_adddup2(&actions, err[1], 2)
  var flags = Int32(POSIX_SPAWN_SETPGROUP)
  #if canImport(Darwin)
    flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
  #endif
  posix_spawnattr_setflags(&attr, Int16(flags))
  posix_spawnattr_setpgroup(&attr, 0)

  let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
  let envp: [UnsafeMutablePointer<CChar>?] =
    env.map { cString($0.name + [UInt8(ascii: "=")] + $0.value) } + [nil]
  defer {
    for pointer in argv + envp { free(pointer) }
  }

  var pid: pid_t = 0
  var spawned = posix_spawn(&pid, path, &actions, &attr, argv, envp)
  #if !canImport(Darwin)
    // Another thread's child can briefly hold a just-written script open
    // for writing; Darwin's POSIX_SPAWN_CLOEXEC_DEFAULT rules that out.
    for _ in 0..<50 where spawned == ETXTBSY {
      usleep(10_000)
      spawned = posix_spawn(&pid, path, &actions, &attr, argv, envp)
    }
  #endif
  close(out[1])
  close(err[1])
  guard spawned == 0 else {
    close(out[0])
    close(err[0])
    throw spawned == ENOENT ? .notInstalled : .spawn(errorText(spawned))
  }

  let deadline = ContinuousClock.now + timeout
  var open = [out[0], err[0]]
  func stop() -> GhError {
    killpg(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    for fd in open { close(fd) }
    return .timeout(timeout)
  }

  var stdout: [UInt8] = []
  var stderr: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 65536)
  while !open.isEmpty {
    let left = deadline - ContinuousClock.now
    guard left > .zero else { throw stop() }
    var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
    let ready = poll(&fds, nfds_t(fds.count), milliseconds(min(left, .seconds(1))))
    if ready < 0 && errno != EINTR { throw stop() }
    for fd in fds where fd.revents != 0 {
      let n = read(fd.fd, &chunk, chunk.count)
      if n > 0 {
        if fd.fd == out[0] { stdout += chunk[0..<n] } else { stderr += chunk[0..<n] }
      } else if n == 0 || errno != EINTR {
        close(fd.fd)
        open.removeAll { $0 == fd.fd }
      }
    }
  }

  var status: Int32 = 0
  while true {
    let reaped = waitpid(pid, &status, WNOHANG)
    if reaped == pid { break }
    if reaped < 0 && errno != EINTR { throw .spawn(errorText(errno)) }
    guard ContinuousClock.now < deadline else { throw stop() }
    usleep(20_000)
  }
  // WIFEXITED and WEXITSTATUS are macros Swift doesn't import.
  let exited = status & 0x7f == 0
  return Output(status: exited ? (status >> 8) & 0xff : nil, stdout: stdout, stderr: stderr)
}

private func milliseconds(_ d: Duration) -> Int32 {
  let (seconds, attoseconds) = d.components
  return max(1, Int32(seconds * 1000 + attoseconds / 1_000_000_000_000_000))
}

private func cString(_ bytes: [UInt8]) -> UnsafeMutablePointer<CChar>? {
  let p = malloc(bytes.count + 1)!.assumingMemoryBound(to: CChar.self)
  bytes.withUnsafeBytes { raw in
    if let base = raw.baseAddress { memcpy(p, base, bytes.count) }
  }
  p[bytes.count] = 0
  return p
}

func errorText(_ code: Int32) -> String {
  String(cString: strerror(code))
}

/// The inherited environment with `overlay` set over it.
func merged(_ overlay: [EnvVar]) -> [EnvVar] {
  var result: [EnvVar] = []
  var entry = environ
  while let pointer = entry.pointee {
    let bytes = Array(UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
    if let eq = bytes.firstIndex(of: UInt8(ascii: "=")) {
      let name = Array(bytes[..<eq])
      if !overlay.contains(where: { $0.name == name }) {
        result.append(EnvVar(name, Array(bytes[(eq + 1)...])))
      }
    }
    entry += 1
  }
  return result + overlay
}

/// posix_spawnp would search the parent's PATH; like a shell, this searches
/// the child's, which a Finder launch's login-shell PATH depends on.
func resolve(_ program: String, env: [EnvVar]) -> String? {
  if program.contains("/") { return program }
  let path = env.last { $0.name == Array("PATH".utf8) }?.value ?? []
  return directories(path).lazy.map { $0 + "/" + program }.first(where: isExecutableFile)
}

/// A PATH's directories; an empty entry is the current directory.
func directories(_ path: [UInt8]) -> [String] {
  path.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false).map {
    $0.isEmpty ? "." : String(decoding: $0, as: UTF8.self)
  }
}

func isExecutableFile(_ path: String) -> Bool {
  var info = stat()
  guard stat(path, &info) == 0 else { return false }
  return info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o111 != 0
}
