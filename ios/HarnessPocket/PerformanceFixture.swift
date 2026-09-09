// Deterministic simulator workload; never compiled into distribution builds.
#if DEBUG
import Foundation
import Darwin

@MainActor enum PerformanceFixture {
    static func run(_ model: AppModel) async {
        guard ProcessInfo.processInfo.arguments.contains("--performance-qa") else { return }
        let history: [[String: Any]] = (0..<80).map { index in
            ["id": "perf-\(index)", "role": "assistant", "text": String(repeating: "**回答**：長い会話を確認しています。\n", count: 24), "reasoning": String(repeating: "推論の内容も保持しています。\n", count: 40)]
        }
        func update(_ n: Int, running: Bool) {
            model.currentID = "performance-qa"
            model.chat = ChatSnapshot(["id": "performance-qa", "running": running, "messages": history + [["id": "live", "role": "assistant", "streaming": running, "reasoning": String(repeating: "新しい推論の断片を受信しました。\n", count: 200 + n), "text": running ? "" : "負荷テスト完了"]]])
        }
        update(0, running: true)
        try? await Task.sleep(for: .seconds(3))
        let started = ProcessInfo.processInfo.systemUptime
        let cpu = clock()
        for n in 1...60 {
            guard !Task.isCancelled else { return }
            update(n, running: true)
            try? await Task.sleep(for: .milliseconds(250))
        }
        let cpuSeconds = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
        let wallSeconds = ProcessInfo.processInfo.systemUptime - started
        update(60, running: false)
        try? await Task.sleep(for: .seconds(2))
        let idleCPU = clock()
        try? await Task.sleep(for: .seconds(3))
        let result: [String: Any] = ["updates": 60, "historyRows": 80, "cpuSeconds": cpuSeconds, "wallSeconds": wallSeconds, "idleCPUSeconds": Double(clock() - idleCPU) / Double(CLOCKS_PER_SEC)]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("performance-qa.json")
        try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: url)
    }
}
#endif
