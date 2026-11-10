import Foundation

enum DefaultPhrases {
    static let all: [SavedPhrase] = [
        phrase(1, "继续执行", "Continue",
               "请继续完成剩余任务，完成后告诉我结果。",
               "Please continue with the remaining tasks and let me know the results when you are done."),
        phrase(2, "确认方案", "Confirm the plan",
               "好的，按这个方案执行。完成后说明结果和需要我处理的事项。",
               "Sounds good. Please proceed with this plan, then report the results and anything that needs my attention."),
        phrase(3, "先列计划", "Make a plan first",
               "请先梳理目标和约束，列出简洁的执行步骤、验证方式及需要确认的问题，等我确认后再开始。",
               "Please clarify the goals and constraints, then outline concise steps, validation methods, and any open questions. Wait for my confirmation before starting."),
        phrase(4, "澄清需求", "Clarify requirements",
               "请指出当前需求中不明确的地方，只询问会影响结果的关键问题，并给出可选方案。",
               "Please identify ambiguities in the requirements. Ask only the key questions that affect the outcome and provide options."),
        phrase(5, "解释一下", "Explain",
               "请用通俗的语言解释这部分的作用、实现思路和关键取舍，必要时给一个简单例子。",
               "Please explain what this does, how it works, and the key tradeoffs in plain language. Include a simple example if helpful."),
        phrase(6, "简要总结", "Summarize",
               "请简要总结当前结论、已完成事项、尚未解决的问题和下一步。",
               "Please briefly summarize the conclusions, completed work, unresolved issues, and next steps."),
        phrase(7, "对比方案", "Compare options",
               "请对比这些方案的优缺点、实现成本、风险和适用场景，给出建议并说明理由。",
               "Please compare the options in terms of benefits, drawbacks, implementation effort, risks, and suitable use cases. Recommend one and explain why."),
        phrase(8, "检查遗漏", "Check for gaps",
               "请对照原始需求检查是否有遗漏，特别关注边界情况、异常处理和兼容性，并列出需要补充的事项。",
               "Please check the result against the original requirements for omissions, especially edge cases, error handling, and compatibility. List anything that still needs attention."),
        phrase(9, "定位问题", "Diagnose the issue",
               "请先复现问题并定位原因，结合日志或代码给出证据，再提出范围最小的修复方案。",
               "Please reproduce the issue and identify its cause. Support your findings with logs or code evidence, then propose the smallest appropriate fix."),
        phrase(10, "修复问题", "Fix the issue",
               "请修复这个问题，尽量缩小改动范围，保留现有功能，并验证修复结果。",
               "Please fix this issue with a focused change, preserve existing functionality, and verify the result."),
        phrase(11, "补充测试", "Add tests",
               "请为这次改动补充必要的测试，覆盖正常流程、边界情况和失败路径，并运行相关测试。",
               "Please add the tests needed for this change, covering normal behavior, edge cases, and failure paths, then run the relevant tests."),
        phrase(12, "检查结果", "Verify the result",
               "请检查实现是否符合需求，运行相关测试和构建，并说明通过情况及尚未验证的部分。",
               "Please verify that the implementation meets the requirements, run the relevant tests and build, and report what passed and what remains unverified."),
        phrase(13, "优化实现", "Improve the implementation",
               "请在保持现有行为的前提下简化实现，减少重复和不必要的复杂度，并说明改动收益。",
               "Please simplify the implementation while preserving its behavior. Reduce duplication and unnecessary complexity, and explain the benefits."),
        phrase(14, "审查修改", "Review the changes",
               "请审查本次改动，优先查找实际缺陷、回归风险和测试缺口，按严重程度列出具体位置及原因。",
               "Please review these changes for bugs, regression risks, and missing tests. List findings by severity with specific locations and explanations."),
        phrase(15, "润色表达", "Polish the wording",
               "请在保留原意和关键信息的基础上润色这段文字，让表达自然、清晰、简洁，避免空话。",
               "Please polish this text while preserving its meaning and key information. Make it natural, clear, and concise, without filler."),
        phrase(16, "整理交接", "Prepare a handoff",
               "请整理一份简洁的交接说明，包括目标、当前进展、关键决定、相关文件、验证结果和后续待办。",
               "Please prepare a concise handoff covering the goal, current progress, key decisions, relevant files, validation results, and remaining tasks."),
    ]

    static func addingMissing(to phrases: [SavedPhrase]) -> [SavedPhrase] {
        var result = phrases
        for var preset in all {
            guard !result.contains(where: {
                $0.id == preset.id || ($0.text == preset.text && $0.englishText == preset.englishText)
            }) else { continue }
            preset.title = uniqueName(preset.title, existingNames: result.map(\.title), fallback: "AI 常用语")
            result.append(preset)
        }
        return result
    }

    static func assignments(for phrases: [SavedPhrase]) -> PhraseAssignments {
        let recommendations: [(ControllerInput, Int)] = [
            (.dpadUp, 1), (.dpadDown, 12), (.dpadLeft, 5), (.dpadRight, 10), (.buttonA, 2),
        ]
        var assignments = PhraseAssignments()
        for (input, number) in recommendations {
            let preset = all.first { $0.id == identifier(number) }!
            // Seeding can reuse an existing phrase with identical bilingual
            // content, so bind that saved ID when the preset ID is absent.
            let phrase = phrases.first { $0.id == preset.id }
                ?? phrases.first { $0.text == preset.text && $0.englishText == preset.englishText }
            assignments[input] = phrase?.id
        }
        return assignments
    }

    private static func identifier(_ number: Int) -> UUID {
        UUID(uuidString: "A1F00000-0000-4000-8000-" + String(format: "%012d", number))!
    }

    private static func phrase(_ number: Int, _ title: String, _ englishTitle: String,
                               _ text: String, _ englishText: String) -> SavedPhrase {
        SavedPhrase(id: identifier(number), title: title, text: text, englishTitle: englishTitle, englishText: englishText)
    }
}
