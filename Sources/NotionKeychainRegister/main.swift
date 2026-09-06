import Darwin
import Foundation

private func safeName(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128 && value.allSatisfy { ch in
        (ch.isASCII && (ch.isLetter || ch.isNumber)) || "-_.@".contains(ch)
    }
}

private func finish(_ url: URL, _ state: String) -> Never {
    try? Data("{\"state\":\"\(state)\"}\n".utf8).write(to: url, options: .atomic)
    exit(state == "saved" ? 0 : 1)
}

guard CommandLine.arguments.count == 4 else {
    fputs("사용법 오류\n", stderr); exit(2)
}
let service = CommandLine.arguments[1]
let account = CommandLine.arguments[2]
let resultURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard safeName(service), safeName(account), isatty(STDIN_FILENO) == 1 else {
    finish(resultURL, "rejected")
}

fputs("Notion 통합 토큰을 입력하세요 (화면에 표시되지 않습니다): ", stderr)
func readHiddenLine() -> String? {
    var old = termios()
    guard tcgetattr(STDIN_FILENO, &old) == 0 else { return nil }
    var hidden = old
    hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else { return nil }
    defer { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &old) }
    return readLine()
}
guard let token = readHiddenLine() else { finish(resultURL, "tty_failed") }
fputs("\n", stderr)
guard !token.isEmpty, token.count <= 4096,
      token.allSatisfy({ ch in
          guard let byte = ch.asciiValue, byte > 0x20, byte < 0x7f else { return false }
          return !"\"\\'`$".contains(ch)
      }) else {
    finish(resultURL, token.isEmpty ? "cancelled" : "invalid")
}

let security = Process()
security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
security.arguments = ["-i"]
let input = Pipe()
let output = Pipe()
security.standardInput = input
security.standardOutput = output
security.standardError = output
do { try security.run() } catch { finish(resultURL, "security_failed") }
// 토큰은 security의 stdin에만 쓰며 argv/env/결과 파일에는 넣지 않는다.
let command = "add-generic-password -U -s \(service) -a \(account) -w \"\(token)\"\n"
input.fileHandleForWriting.write(Data(command.utf8))
try? input.fileHandleForWriting.close()
security.waitUntilExit()
finish(resultURL, security.terminationStatus == 0 ? "saved" : "security_failed")
