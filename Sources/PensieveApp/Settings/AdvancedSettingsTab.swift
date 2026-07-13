import SwiftUI
import PensieveKit

struct AdvancedSettingsTab: View {
  @ObservedObject var model: AppModel
  var body: some View {
    Form { }
      .formStyle(.grouped)
      .frame(width: 460)
  }
}
