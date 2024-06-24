import SwiftUI
import ARKit
import Vision

struct ARViewContainer: UIViewRepresentable {
    @Binding var detectedObjects: [DetectedObject]
    @Binding var isCalibrating: Bool
    
    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView(frame: .zero)
        sceneView.delegate = context.coordinator
        sceneView.session.delegate = context.coordinator
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        
        context.coordinator.sceneView = sceneView // Store reference to sceneView in coordinator
        
        return sceneView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Update session configuration if necessary
        if uiView.session.configuration == nil {
            let configuration = ARWorldTrackingConfiguration()
            configuration.environmentTexturing = .automatic
            
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = .mesh
            }
            
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            
            uiView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        var parent: ARViewContainer
        var sceneView: ARSCNView? // Reference to the sceneView
        private var yoloModel: VNCoreMLModel?
        private var trackedPositions: [TrackedPosition] = []
        
        init(_ parent: ARViewContainer) {
            self.parent = parent
            super.init()
            loadYOLOModel()
        }
        
        private func loadYOLOModel() {
            guard let model = try? VNCoreMLModel(for: yolov8n().model) else {
                fatalError("Failed to load YOLOv8 model")
            }
            yoloModel = model
        }
        
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard let yoloModel = yoloModel else { return }
            
            let pixelBuffer = frame.capturedImage
            let request = VNCoreMLRequest(model: yoloModel) { [weak self] request, error in
                if let results = request.results as? [VNRecognizedObjectObservation] {
                    self?.handleYOLODetections(results, frame: frame)
                }
            }
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
            
            // Check tracking state
            switch frame.camera.trackingState {
            case .normal:
                parent.isCalibrating = false
            case .notAvailable, .limited:
                parent.isCalibrating = true
            }
        }
        
        private func handleYOLODetections(_ detections: [VNRecognizedObjectObservation], frame: ARFrame) {
            guard let sceneView = sceneView else {
                print("No valid scene view")
                return
            }
            
            var newDetectedObjects: [DetectedObject] = []
            for detection in detections {
                let objectName = detection.labels.first?.identifier ?? "Unknown"
                if objectName == "sports ball" {
                    let boundingBox = detection.boundingBox
                    let convertedRect = convertBoundingBox(boundingBox, imageResolution: frame.camera.imageResolution, viewSize: sceneView.bounds.size)
                    let center = CGPoint(x: convertedRect.midX, y: convertedRect.midY)
                    let distance = distanceAtPoint(center, frame: frame)
                    let accuracy = detection.confidence
                    let worldPosition = convertToWorldPosition(center, frame: frame)
                    newDetectedObjects.append(DetectedObject(boundingBox: convertedRect, distance: distance, objectName: objectName, accuracy: accuracy, worldPosition: worldPosition, timestamp: frame.timestamp))
                    
                    trackObject(worldPosition, timestamp: frame.timestamp)
                }
            }
            DispatchQueue.main.async {
                self.parent.detectedObjects = newDetectedObjects
            }
        }
        
        private func distanceAtPoint(_ point: CGPoint, frame: ARFrame) -> Float {
            guard let sceneView = sceneView else { return -1 }
            
            if let depthData = frame.sceneDepth {
                let depthMap = depthData.depthMap
                let depthWidth = CVPixelBufferGetWidth(depthMap)
                let depthHeight = CVPixelBufferGetHeight(depthMap)
                let x = Int(point.x * CGFloat(depthWidth) / sceneView.bounds.width)
                let y = Int(point.y * CGFloat(depthHeight) / sceneView.bounds.height)
                
                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
                
                let rowData = CVPixelBufferGetBaseAddress(depthMap)!.assumingMemoryBound(to: Float32.self)
                let distance = rowData[y * depthWidth + x]
                
                return distance
            } else {
                // Handle non-LiDAR devices: Use raycasting
                let raycastQuery = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
                let results = sceneView.session.raycast(raycastQuery!)
                guard let result = results.first else { return -1 }
                
                let distance = simd_distance(result.worldTransform.columns.3, simd_float4(0, 0, 0, 1))
                return distance
            }
        }
        
        private func convertBoundingBox(_ boundingBox: CGRect, imageResolution: CGSize, viewSize: CGSize) -> CGRect {
            // Convert bounding box from normalized coordinates to view coordinates
            let widthScale = viewSize.width / imageResolution.width
            let heightScale = viewSize.height / imageResolution.height
            
            let x = boundingBox.origin.x * viewSize.width
            let y = (1 - boundingBox.origin.y - boundingBox.size.height) * viewSize.height
            let width = boundingBox.size.width * viewSize.width
            let height = boundingBox.size.height * viewSize.height
            
            return CGRect(x: x, y: y, width: width, height: height)
        }
        
        private func convertToWorldPosition(_ point: CGPoint, frame: ARFrame) -> simd_float3? {
            guard let sceneView = sceneView else { return nil }
            
            if let depthData = frame.sceneDepth {
                let depthMap = depthData.depthMap
                let depthWidth = CVPixelBufferGetWidth(depthMap)
                let depthHeight = CVPixelBufferGetHeight(depthMap)
                let x = Int(point.x * CGFloat(depthWidth) / sceneView.bounds.width)
                let y = Int(point.y * CGFloat(depthHeight) / sceneView.bounds.height)
                
                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
                
                let rowData = CVPixelBufferGetBaseAddress(depthMap)!.assumingMemoryBound(to: Float32.self)
                let depth = rowData[y * depthWidth + x]
                
                let raycastQuery = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
                let results = sceneView.session.raycast(raycastQuery!)
                guard let result = results.first else { return nil }
                
                let position = result.worldTransform.columns.3
                return simd_float3(position.x, position.y, position.z - depth)
            } else {
                // Handle non-LiDAR devices: Use raycasting
                let raycastQuery = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
                let results = sceneView.session.raycast(raycastQuery!)
                guard let result = results.first else { return nil }
                
                let position = result.worldTransform.columns.3
                return simd_float3(position.x, position.y, position.z)
            }
        }
        
        private func trackObject(_ position: simd_float3?, timestamp: TimeInterval) {
            guard let position = position else { return }
            trackedPositions.append(TrackedPosition(position: position, timestamp: timestamp))
            
            if trackedPositions.count > 2 {
                let speed = calculateSpeed()
                print("Object speed: \(speed) m/s")
                
                // Remove old positions to keep only the recent ones for speed calculation
                trackedPositions = Array(trackedPositions.suffix(5))
            }
        }
        
        private func calculateSpeed() -> Float {
            guard trackedPositions.count >= 2 else { return 0.0 }
            let lastPosition = trackedPositions[trackedPositions.count - 1]
            let secondLastPosition = trackedPositions[trackedPositions.count - 2]
            
            let distance = simd_distance(lastPosition.position, secondLastPosition.position)
            let timeInterval = Float(lastPosition.timestamp - secondLastPosition.timestamp)
            
            return distance / timeInterval
        }
        
        // MARK: - ARSessionDelegate methods for handling interruptions and errors

        func sessionWasInterrupted(_ session: ARSession) {
            print("AR session was interrupted.")
            parent.isCalibrating = true
        }
        
        func sessionInterruptionEnded(_ session: ARSession) {
            print("AR session interruption ended.")
            restartSession()
        }
        
        func session(_ session: ARSession, didFailWithError error: Error) {
            print("AR session failed with error: \(error.localizedDescription)")
            restartSession()
        }
        
        private func restartSession() {
            guard let sceneView = sceneView else { return }
            let configuration = ARWorldTrackingConfiguration()
            configuration.environmentTexturing = .automatic
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = .mesh
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }
}

struct DetectedObject: Identifiable {
    let id = UUID()
    let boundingBox: CGRect
    let distance: Float
    let objectName: String
    let accuracy: VNConfidence
    let worldPosition: simd_float3?
    let timestamp: TimeInterval
}

struct TrackedPosition {
    let position: simd_float3
    let timestamp: TimeInterval
}
