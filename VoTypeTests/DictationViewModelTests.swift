import XCTest
@testable import VoiceInputApp

final class DictationViewModelTests: XCTestCase {

    func testLoadSettingsFromURL() {
        let url = URL(string: "votype://dictation?lang=en-US&whisper=1&session=test-123")
        let viewModel = DictationViewModel()
        viewModel.loadSettings(from: url)

        // viewModel 的属性是 private,我们只能验证不崩溃
        // 如果 loadSettings 解析失败会崩溃
    }

    func testLoadSettingsFromNilURL() {
        let viewModel = DictationViewModel()
        viewModel.loadSettings(from: nil)
        // 不应该崩溃,使用默认值
    }

    func testLoadSettingsWithSelectedText() {
        let url = URL(string: "votype://dictation?lang=zh-CN&whisper=0&selectedText=hello&session=test-456")
        let viewModel = DictationViewModel()
        viewModel.loadSettings(from: url)
    }

    func testLoadSettingsWithTranslate() {
        let url = URL(string: "votype://dictation?lang=zh-CN&whisper=0&translate=1&translateTarget=en&session=test-789")
        let viewModel = DictationViewModel()
        viewModel.loadSettings(from: url)
    }

    func testStopRecordingWithoutStart() {
        let viewModel = DictationViewModel()
        viewModel.stopRecording()
        // 不应该崩溃
    }

    func testCleanupWithoutStart() {
        let viewModel = DictationViewModel()
        viewModel.cleanup()
        // 不应该崩溃
    }
}
