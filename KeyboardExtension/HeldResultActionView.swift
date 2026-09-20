import UIKit

final class HeldResultActionView: UIStackView {
    var onInsert: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDiscard: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        distribution = .fillEqually
        spacing = 8
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(makeButton(title: "插入", action: #selector(insertTapped)))
        addArrangedSubview(makeButton(title: "复制", action: #selector(copyTapped)))
        addArrangedSubview(makeButton(title: "丢弃", action: #selector(discardTapped)))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = title
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func insertTapped() { onInsert?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func discardTapped() { onDiscard?() }
}
