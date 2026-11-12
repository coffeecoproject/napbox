import Foundation
import Testing
@testable import NapboxCore

@Suite struct SourceChangesTests {
    private let mounts = [SourceMount(hostRoot: "/h/src", guardRoot: "/napbox-src/0")]

    private func file(_ modified: Int64 = 1, mode: UInt32 = 0o644, inode: UInt64 = 1, size: Int64 = 1, symlink: Bool = false) -> SourceFileStat {
        SourceFileStat(inode: inode, modifiedNanoseconds: modified, size: size, mode: mode, isSymlink: symlink)
    }

    @Test func changedFileGetsItsOwnMode() {
        var planner = SourceChangePlanner(mounts: mounts)
        let result = planner.notifications(for: ["/h/src/a/b.ts"]) { _ in file(mode: 0o755) }
        #expect(result == [SourceNotification(path: "/napbox-src/0/a/b.ts", mode: 0o755)])
    }

    /// 通知本身会让宿主机再报一次变化：文件的样子没变就不再发，否则没完没了
    @Test func eventCausedByTheNotificationIsDropped() {
        var planner = SourceChangePlanner(mounts: mounts)
        let now = Date()
        #expect(planner.notifications(for: ["/h/src/a"], now: now) { _ in file() }.count == 1)
        #expect(planner.notifications(for: ["/h/src/a"], now: now.addingTimeInterval(0.1)) { _ in file() }.isEmpty)
    }

    /// 改名覆盖（mv 保留修改时间）、大小不变的保存、改权限：都是真的变了
    @Test func anyRealChangeIsForwardedAgain() {
        let now = Date()
        for changed in [file(2), file(inode: 2), file(size: 2), file(mode: 0o600)] {
            var planner = SourceChangePlanner(mounts: mounts)
            _ = planner.notifications(for: ["/h/src/a"], now: now) { _ in file() }
            #expect(planner.notifications(for: ["/h/src/a"], now: now) { _ in changed }.count == 1)
        }
    }

    @Test func rememberedOnlyForAWhile() {
        var planner = SourceChangePlanner(mounts: mounts)
        let now = Date()
        _ = planner.notifications(for: ["/h/src/a"], now: now) { _ in file() }
        #expect(planner.notifications(for: ["/h/src/a"], now: now.addingTimeInterval(31)) { _ in file() }.count == 1)
    }

    @Test func deletedFileNotifiesItsDirectory() {
        var planner = SourceChangePlanner(mounts: mounts)
        let result = planner.notifications(for: ["/h/src/d/x"]) { $0 == "/h/src/d" ? file(mode: 0o755) : nil }
        #expect(result == [SourceNotification(path: "/napbox-src/0/d", mode: 0o755)])
    }

    /// 虚拟化框架不让改共享根目录的属性，所以只能发信号
    @Test func deletedDirectChildSignalsTheRoot() {
        var planner = SourceChangePlanner(mounts: mounts)
        #expect(planner.notifications(for: ["/h/src/x"]) { _ in nil } == [SourceNotification(path: "/napbox-src/0", mode: nil)])
    }

    @Test func deletedTreeWalksUpToWhatStillExists() {
        var planner = SourceChangePlanner(mounts: mounts)
        let result = planner.notifications(for: ["/h/src/a/b/c/x"]) { $0 == "/h/src/a" ? file() : nil }
        #expect(result == [SourceNotification(path: "/napbox-src/0/a", mode: 0o644)])
    }

    /// chmod 符号链接会改到它指向的文件
    @Test func symlinkIsNeverChmodded() {
        var planner = SourceChangePlanner(mounts: mounts)
        let result = planner.notifications(for: ["/h/src/d/link"]) { $0 == "/h/src/d" ? file(mode: 0o755) : file(mode: 0o777, symlink: true) }
        #expect(result == [SourceNotification(path: "/napbox-src/0/d", mode: 0o755)])
    }

    @Test func ignoredPaths() {
        var planner = SourceChangePlanner(mounts: mounts)
        let paths = ["/h/src", "/h/src/.git/index.lock", "/h/src/sub/.git/x", "/h/src/.napbox-notify-3", "/h/srcother/a", "/elsewhere/a"]
        #expect(planner.notifications(for: paths) { _ in file() }.isEmpty)
    }

    @Test func nestedMountsBothGetIt() {
        var planner = SourceChangePlanner(mounts: mounts + [SourceMount(hostRoot: "/h/src/sub", guardRoot: "/napbox-src/1")])
        let result = planner.notifications(for: ["/h/src/sub/a"]) { _ in file() }
        #expect(result.map(\.path) == ["/napbox-src/0/sub/a", "/napbox-src/1/a"])
    }

    /// 挂的是单个文件：只管这个文件自己，同一个目录里别的文件不相干
    @Test func fileMountOnlyFollowsThatFile() {
        var planner = SourceChangePlanner(mounts: [SourceMount(hostRoot: "/h/app/package.json", guardRoot: "/napbox-src/0/package.json", isFile: true)])
        let result = planner.notifications(for: ["/h/app/package.json", "/h/app/other.json", "/h/app", "/h/app/package.json/x", "/h/app/package.jsonx"]) { _ in file(mode: 0o600) }
        #expect(result == [SourceNotification(path: "/napbox-src/0/package.json", mode: 0o600)])
    }

    /// 文件在宿主机上被删了、换成了符号链接：容器里挂着的还是原来那一个，不发
    @Test func fileMountGoneSendsNothing() {
        let mounts = [SourceMount(hostRoot: "/h/app/package.json", guardRoot: "/napbox-src/0/package.json", isFile: true)]
        var planner = SourceChangePlanner(mounts: mounts)
        #expect(planner.notifications(for: ["/h/app/package.json"]) { _ in nil }.isEmpty)
        planner = SourceChangePlanner(mounts: mounts)
        #expect(planner.notifications(for: ["/h/app/package.json"]) { _ in file(symlink: true) }.isEmpty)
    }

    /// 一个服务挂整个目录，另一个只挂里面的一个文件：是同一份共享，只发一次
    @Test func fileMountInsideADirectoryMountIsSentOnce() {
        var planner = SourceChangePlanner(mounts: mounts + [SourceMount(hostRoot: "/h/src/vite.config.ts", guardRoot: "/napbox-src/0/vite.config.ts", isFile: true)])
        let result = planner.notifications(for: ["/h/src/vite.config.ts"]) { _ in file() }
        #expect(result == [SourceNotification(path: "/napbox-src/0/vite.config.ts", mode: 0o644)])
    }

    /// 目录在它里面的文件之前，监听的程序先看到目录
    @Test func sortedParentsFirst() {
        var planner = SourceChangePlanner(mounts: mounts)
        let result = planner.notifications(for: ["/h/src/d/e/f", "/h/src/d", "/h/src/d/e"]) { _ in file() }
        #expect(result.map(\.path) == ["/napbox-src/0/d", "/napbox-src/0/d/e", "/napbox-src/0/d/e/f"])
    }
}
