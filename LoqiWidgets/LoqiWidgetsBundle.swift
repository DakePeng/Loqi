import SwiftUI
import WidgetKit

@main
struct LoqiWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordingControl()
    }
}
