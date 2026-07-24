import SwiftUI

struct RecentlyDeletedView: View {
    var body: some View {
        NavigationView {
            VStack {
                Text("Son Silinenler")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            .navigationTitle("Son Silinenler")
        }
    }
}
