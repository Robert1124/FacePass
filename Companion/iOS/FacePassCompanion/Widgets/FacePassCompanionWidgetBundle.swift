import FacePassCompanionCore
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 17.0, *)
@main
struct FacePassCompanionWidgetBundle: WidgetBundle {
    var body: some Widget {
        StandByUnlockWidget()
        StandByUnlockLiveActivityWidget()
    }
}
