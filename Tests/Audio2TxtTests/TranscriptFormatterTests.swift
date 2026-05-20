import Audio2TxtCore
import Testing

@Test("毫秒时间戳格式")
func timestampFormat() {
    #expect(TranscriptFormatter.formatMs(0) == "00:00:00.000")
    #expect(TranscriptFormatter.formatMs(3723004) == "01:02:03.004")
}

@Test("基础句段渲染")
func renderSegments() {
    let json: [String: Any] = [
        "segments": [
            [
                "start_time": 1.5,
                "speaker": "SPK_1",
                "text": "你好"
            ],
            [
                "start_ms": 3000,
                "text": "世界"
            ]
        ]
    ]

    let text = TranscriptFormatter.renderTXT(from: json)
    #expect(text.contains("00:01"))
    #expect(text.contains("你好"))
    #expect(text.contains("世界"))
}

@Test("无标准句段时回退原始 JSON")
func fallbackRawJSON() {
    let json: [String: Any] = ["foo": ["bar": 1]]
    let text = TranscriptFormatter.renderTXT(from: json)
    #expect(text.contains("未识别到标准句段"))
}

@Test("短词会自动合并")
func mergeWordLikeSegments() {
    let json: [String: Any] = [
        "segments": [
            ["start_ms": 1000, "speaker": "SPK_0", "text": "然后"],
            ["start_ms": 1180, "speaker": "SPK_0", "text": "判断"],
            ["start_ms": 1360, "speaker": "SPK_0", "text": "一下"],
            ["start_ms": 1540, "speaker": "SPK_0", "text": "这个"],
            ["start_ms": 1720, "speaker": "SPK_0", "text": "n"],
            ["start_ms": 1900, "speaker": "SPK_0", "text": "是不是"],
            ["start_ms": 2080, "speaker": "SPK_0", "text": "素数。"]
        ]
    ]

    let text = TranscriptFormatter.renderTXT(from: json)
    #expect(text.contains("然后判断一下这个n是不是素数。"))
}

@Test("按音频时长约束时间轴并过滤异常大时间戳")
func clampAndScaleByExpectedDuration() {
    let json: [String: Any] = [
        "audio_transcript": [
            ["start_ms": 1_000, "speaker": "SPK_0", "text": "老师开始讲解"],
            ["start_ms": 9_500, "speaker": "SPK_0", "text": "这是第二句"],
            ["start_ms": 25_000, "speaker": "SPK_0", "text": "这是第三句"],
            // 超出时长的异常句段应被丢弃
            ["start_ms": 4_200_000, "speaker": "SPK_0", "text": "异常段"]
        ],
        "chapters": [
            // 章节时间轴（历史问题里会出现）
            ["start_time": 9_290, "speaker": "SPK_0", "text": "章节一"],
            ["start_time": 34_450, "speaker": "SPK_0", "text": "章节二"]
        ]
    ]

    let text = TranscriptFormatter.renderTXT(from: json, expectedDurationMs: 209_000)
    #expect(text.contains("老师开始讲解"))
    #expect(text.contains("这是第三句"))
    #expect(!text.contains("章节一"))
    #expect(!text.contains("异常段"))
}

@Test("妙记 raw 数组(start_time 毫秒)应完整输出")
func larkRawArrayShouldKeepAllSentences() {
    let json: [[String: Any]] = [
        ["content": "第一段", "start_time": 9290, "end_time": 33890, "speaker": ["id": "1"]],
        ["content": "第二段", "start_time": 34450, "end_time": 41250, "speaker": ["id": "1"]],
        ["content": "第三段", "start_time": 199719, "end_time": 204119, "speaker": ["id": "1"]]
    ]

    let text = TranscriptFormatter.renderTXT(from: json, expectedDurationMs: 209_000)
    #expect(text.contains("00:09"))
    #expect(text.contains("第一段第二段"))
    #expect(text.contains("03:19"))
    #expect(text.contains("第一段"))
    #expect(text.contains("第三段"))
}
