import Testing
@testable import NapboxCore

@Suite struct InterpolationTests {
    let env = ["SET": "v", "EMPTY": ""]

    func run(_ text: String) throws -> String {
        try Interpolator { env[$0] }.interpolate(text)
    }

    @Test func plainAndBraced() throws {
        #expect(try run("a-$SET-${SET}-b") == "a-v-v-b")
        #expect(try run("$$SET costs $$5") == "$SET costs $5")
        #expect(try run("price $ 5") == "price $ 5")
    }

    @Test func defaults() throws {
        #expect(try run("${MISSING:-d}") == "d")
        #expect(try run("${EMPTY:-d}") == "d")
        #expect(try run("${EMPTY-d}") == "")
        #expect(try run("${MISSING-d}") == "d")
        #expect(try run("${SET:-d}") == "v")
        #expect(try run("${MISSING:-${SET}x}") == "vx")
        #expect(try run("${PORT:-8080}:80") == "8080:80")
    }

    @Test func alternatives() throws {
        #expect(try run("${SET:+alt}") == "alt")
        #expect(try run("${EMPTY:+alt}") == "")
        #expect(try run("${EMPTY+alt}") == "alt")
        #expect(try run("${MISSING+alt}") == "")
    }

    @Test func required() throws {
        #expect(try run("${SET:?need}") == "v")
        #expect(try run("${EMPTY?need}") == "")
        #expect(throws: InterpolationError.self) { try run("${EMPTY:?need}") }
        do {
            _ = try run("${MISSING:?MISSING is required}")
            Issue.record("应该报错")
        } catch let error as InterpolationError {
            #expect(error.message == "变量 MISSING 必须设置：MISSING is required")
        }
    }

    @Test func missingIsBlankAndRecorded() throws {
        let i = Interpolator { _ in nil }
        #expect(try i.interpolate("x${A}y$B") == "xy")
        #expect(i.missing == ["A", "B"])
    }

    /// 默认值只在用到时才求值：PORT 设了，就不该把 DEFAULT_PORT 算作"没设置的变量"，也不该因为 NEEDED 报错
    @Test func operandIsLazy() throws {
        let i = Interpolator { $0 == "PORT" ? "1" : nil }
        #expect(try i.interpolate("${PORT:-${DEFAULT_PORT}}") == "1")
        #expect(try i.interpolate("${PORT:-${NEEDED:?x}}") == "1")
        #expect(i.missing.isEmpty)
        #expect(try i.interpolate("${NOPE:-a$$b}") == "a$b")
    }

    @Test func malformed() {
        #expect(throws: InterpolationError.self) { try run("${SET extra}") }
        #expect(throws: InterpolationError.self) { try run("${SET") }
        #expect(throws: InterpolationError.self) { try run("${}") }
        #expect(throws: InterpolationError.self) { try run("${SET:x}") }
    }
}

@Suite struct DotEnvTests {
    @Test func formats() throws {
        let text = """
        # 注释
        A=1
        export B = two words  # 行尾注释
        C='lit $A'
        D="line\\nnext $A"
        E=${A}-${MISSING:-d}
        F="跨
        行"
        G=
        PASSTHROUGH
        """
        let parsed = try DotEnv.parse(text, file: ".env") { $0 == "PASSTHROUGH" ? "from-caller" : nil }
        let map = Dictionary(uniqueKeysWithValues: parsed)
        #expect(map["A"] == "1")
        #expect(map["B"] == "two words")
        #expect(map["C"] == "lit $A")
        #expect(map["D"] == "line\nnext 1")
        #expect(map["E"] == "1-d")
        #expect(map["F"] == "跨\n行")
        #expect(map["G"] == "")
        #expect(map["PASSTHROUGH"] == "from-caller")
    }

    @Test func unclosedQuote() {
        #expect(throws: ComposeError.self) { try DotEnv.parse("A=\"oops", file: ".env") { _ in nil } }
    }
}

@Suite struct ValueTests {
    @Test func durations() {
        #expect(ComposeValues.seconds("5s") == 5)
        #expect(ComposeValues.seconds("1m30s") == 90)
        #expect(ComposeValues.seconds("500ms") == 0.5)
        #expect(ComposeValues.seconds("1.5h") == 5400)
        #expect(ComposeValues.seconds("10") == 10)
        #expect(ComposeValues.seconds("5x") == nil)
    }

    @Test func sizes() {
        #expect(ComposeValues.bytes("512m") == 512 * 1024 * 1024)
        #expect(ComposeValues.bytes("1g") == 1024 * 1024 * 1024)
        #expect(ComposeValues.bytes("1GB") == 1024 * 1024 * 1024)
        #expect(ComposeValues.bytes("2048") == 2048)
        #expect(ComposeValues.bytes("lots") == nil)
    }

    @Test func shellSplit() {
        #expect(ComposeValues.shellSplit("npm run dev -- --host 0.0.0.0") == ["npm", "run", "dev", "--", "--host", "0.0.0.0"])
        #expect(ComposeValues.shellSplit(#"sh -c "echo 'hi there'""#) == ["sh", "-c", "echo 'hi there'"])
        #expect(ComposeValues.shellSplit(#"a\ b ''"#) == ["a b", ""])
        #expect(ComposeValues.shellSplit("unclosed 'x") == nil)
    }
}
