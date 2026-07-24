import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: AuthenticationViewModel
    
    var body: some View {
        ZStack {
            // Light, subtle gradient background
            LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.05), Color.purple.opacity(0.05), Color.white]),
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            .ignoresSafeArea()
            
            // Abstract Background Shapes for the glass effect to be visible
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 300, height: 300)
                .offset(x: -100, y: -200)
                .blur(radius: 50)
            
            Circle()
                .fill(Color.purple.opacity(0.15))
                .frame(width: 250, height: 250)
                .offset(x: 150, y: 150)
                .blur(radius: 50)
            
            // Glassmorphism Card
            VStack(spacing: 30) {
                // Logo
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 50)
                    .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
                
                Text("Hoş Geldiniz")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.black.opacity(0.8))
                
                Text("Nova ile finansal dünyanıza giriş yapın.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(.black.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                // Google Sign In Button
                Button(action: {
                    viewModel.signInWithGoogle()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue) 
                        
                        Text("Google ile Giriş Yap")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.black.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    )
                }
                .padding(.top, 20)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.white.opacity(0.5)) // Semi-transparent white
                    .background(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(.ultraThinMaterial) // Apple's native glass effect
                    )
            )
            // Liquid glass border
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(LinearGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0.8), Color.white.opacity(0.2)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 30)
        }
        // Force light mode
        .environment(\.colorScheme, .light)
    }
}
