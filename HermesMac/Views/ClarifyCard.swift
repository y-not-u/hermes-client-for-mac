import SwiftUI

/// Server→client `clarify` card: the agent asked the user one to five questions and is blocked
/// until this card answers. Choices mirror the server contract — a card always offers "Other"
/// free text, multi-select answers are sent as a JSON array, and "取消本轮提问" declines them all.
struct ClarifyCard: View {
    let request: ClarifyRequest
    let conversation: Conversation
    var store: AppStore

    private var submitting: Bool { conversation.submittingClarify.contains(request.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)

                Text(request.questions.count > 1 ? "需要你澄清 \(request.questions.count) 个问题" : "需要你澄清")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.blue)

                Spacer()

                Text("已回答 \(request.questions.count - request.unanswered.count)/\(request.questions.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(request.questions) { question in
                questionBlock(question)
            }

            if let error = conversation.clarifyErrors[request.id] {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button("取消本轮提问") { Task { await store.cancelClarify(request, conversation: conversation) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                if submitting {
                    ProgressView().controlSize(.small)
                    Text("正在提交…").font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Button("确认并继续") {
                    Task { await store.submitClarify(request, conversation: conversation) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)
                .disabled(request.isComplete == false)
            }
            .disabled(!store.connected || conversation.uncertain || submitting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func questionBlock(_ question: ClarifyQuestion) -> some View {
        let locked = request.lockedAnswers[question.qid]
        let typing = request.typingQID == question.qid
        let picked = request.selectedChoices[question.qid] ?? []

        VStack(alignment: .leading, spacing: 6) {
            Text(question.question)
                .font(.system(size: 13, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let locked {
                Label("已回答：\(displayAnswer(locked, for: question))", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                ForEach(question.choices, id: \.self) { choice in
                    choiceRow(question, choice: choice, selected: picked.contains(choice))
                }

                otherRow(question, typing: typing)
            }
        }
    }

    @ViewBuilder
    private func choiceRow(_ question: ClarifyQuestion, choice: String, selected: Bool) -> some View {
        Button {
            store.selectClarifyChoice(request, conversation: conversation, qid: question.qid, choice: choice)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected
                    ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (question.multiSelect ? "square" : "circle"))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(ClarifyQuestion.bare(choice))
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(conversation.submittingClarify.contains(request.id))
    }

    @ViewBuilder
    private func otherRow(_ question: ClarifyQuestion, typing: Bool) -> some View {
        if question.isOpenEnded || typing {
            ClarifyTextField(
                text: draftBinding(question.qid),
                placeholder: question.isOpenEnded ? "输入你的答案…" : "其他答案…",
                enabled: !conversation.submittingClarify.contains(request.id)
            )
            .frame(minHeight: 26, maxHeight: 90)
        } else {
            Button {
                store.clarifyTyping(request, conversation: conversation, qid: question.qid, typing: true)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                    Text("其他（输入你的答案）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(conversation.submittingClarify.contains(request.id))
        }
    }

    private func draftBinding(_ qid: String) -> Binding<String> {
        Binding(
            get: { request.drafts[qid] ?? "" },
            set: { store.editClarifyDraft(request, conversation: conversation, qid: qid, text: $0) }
        )
    }

    /// Locked answers come back as the raw wire value: a multi-select answer is a JSON array
    /// string that is only meant to be read back as a list here.
    private func displayAnswer(_ answer: String, for question: ClarifyQuestion) -> String {
        guard question.multiSelect,
              let data = answer.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return answer }
        return list.joined(separator: "、")
    }
}

/// Multiline plain-text field for an open-ended clarify answer: Enter inserts a newline, so an
/// answer never submits the whole card by accident.
private struct ClarifyTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = TransparentOverlayScroller()
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder
        let view = NSTextView()
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 12)
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
        editor.isEditable = enabled
        editor.textColor = .labelColor
        editor.toolTip = placeholder
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClarifyTextField
        init(_ parent: ClarifyTextField) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}
