import SwiftUI

struct ContentView: View {
    @State private var detectedObjects: [DetectedObject] = []
    @State private var isCalibrating: Bool = true
    
    var body: some View {
        ZStack {
            ARViewContainer(detectedObjects: $detectedObjects, isCalibrating: $isCalibrating)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                if let detectedObject = detectedObjects.first(where: { $0.objectName == "sports ball" }) {
                    Text("\(detectedObject.objectName) - \(String(format: "%.2f m", detectedObject.distance)) - \(String(format: "%.2f", detectedObject.accuracy * 100))%")
                        .padding(5)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    if let speed = detectedObject.worldPosition != nil ? calculateSpeed(for: detectedObject) : nil {
                        Text("Speed: \(String(format: "%.2f", speed)) m/s")
                            .padding(5)
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
            
            if isCalibrating {
                VStack {
                    Text("Move your device around to calibrate AR.")
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    Spacer()
                }
                .padding()
            } else {
                ForEach(detectedObjects) { detectedObject in
                    if detectedObject.objectName == "sports ball" {
                        VStack {
                            Spacer()
                            Rectangle()
                                .stroke(Color.red, lineWidth: 2)
                                .frame(width: detectedObject.boundingBox.width, height: detectedObject.boundingBox.height)
                                .position(x: detectedObject.boundingBox.midX, y: detectedObject.boundingBox.midY)
                        }
                    }
                }
            }
        }
    }
    
    private func calculateSpeed(for detectedObject: DetectedObject) -> Float {
        // Placeholder function to calculate speed based on detected object positions
        // This function should use the same logic as in the ARViewContainer's Coordinator class
        return 0.0
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
