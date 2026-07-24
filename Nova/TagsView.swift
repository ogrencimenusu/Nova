import SwiftUI

struct TagsView: View {
    var body: some View {
        NavigationView {
            VStack {
                Text("Etiketler")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            .navigationTitle("Etiketler")
        }
    }
}
