import SceneKit
import SwiftUI
import UIKit

/// Native SceneKit preview of an STL / OBJ / 3MF model.
/// Rotate, zoom and pan come from SceneKit's camera controls; "reset view"
/// re-frames the model, and the bounding box dimensions are shown below.
struct ModelViewer3D: View {
    let mesh: LoadedMesh
    var showsBuildPlate = true
    /// Caller-supplied, from the slicing profile or the printer's own
    /// axis limits. The default is a neutral placeholder for previews only -
    /// it is never the size of any real machine.
    var buildVolume: SIMD3<Float> = SIMD3(200, 200, 200)

    @State private var sceneID = UUID()
    @State private var wireframe = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                SceneView(
                    scene: makeScene(),
                    pointOfView: nil,
                    options: [.allowsCameraControl, .autoenablesDefaultLighting, .rendersContinuously]
                )
                .id(sceneID)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))

                HStack(spacing: 8) {
                    Button {
                        wireframe.toggle()
                        sceneID = UUID()
                    } label: {
                        Image(systemName: wireframe ? "cube.transparent.fill" : "cube.transparent")
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Button {
                        sceneID = UUID()
                        Haptics.selection()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .padding(10)
            }

            HStack(spacing: 12) {
                StatTile(
                    titleKey: "preview.dimensions",
                    value: mesh.boundingBoxDescription,
                    systemImage: "ruler"
                )
                StatTile(
                    titleKey: "preview.triangles",
                    value: "\(mesh.triangleCount)",
                    systemImage: "triangle"
                )
            }

            if !fitsBuildVolume {
                Label(L.t("preview.too_large"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var fitsBuildVolume: Bool {
        let size = mesh.size
        return size.x <= buildVolume.x && size.y <= buildVolume.y && size.z <= buildVolume.z
    }

    // MARK: - Scene

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.systemGray6

        let node = SCNNode(geometry: makeGeometry())
        // Centre the model on the origin and put its base on the plate.
        let center = mesh.center
        let minimum = mesh.minimum
        node.position = SCNVector3(-center.x, -center.y, -minimum.z)

        let container = SCNNode()
        container.addChildNode(node)
        // STL/3MF are Z-up; SceneKit is Y-up.
        container.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(container)

        if showsBuildPlate {
            scene.rootNode.addChildNode(makePlate())
        }

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 10_000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let size = mesh.size
        let radius = max(max(size.x, size.y), size.z)
        let distance = max(60, radius * 2.2)
        cameraNode.position = SCNVector3(distance * 0.8, distance * 0.65, distance * 0.9)
        cameraNode.look(at: SCNVector3(0, size.z / 2, 0))
        scene.rootNode.addChildNode(cameraNode)

        let light = SCNLight()
        light.type = .directional
        light.intensity = 700
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(distance, distance, distance)
        lightNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(lightNode)

        return scene
    }

    private func makeGeometry() -> SCNGeometry {
        let vertexSource = SCNGeometrySource(vertices: mesh.positions)
        let normalSource = SCNGeometrySource(normals: mesh.normals)

        let indices = (0..<Int32(mesh.positions.count)).map { $0 }
        let element = SCNGeometryElement(
            indices: indices,
            primitiveType: .triangles
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(red: 0.24, green: 0.55, blue: 0.95, alpha: 1)
        material.metalness.contents = 0.05
        material.roughness.contents = 0.55
        material.isDoubleSided = true
        if wireframe {
            material.fillMode = .lines
            material.diffuse.contents = UIColor.white
        }
        geometry.materials = [material]
        return geometry
    }

    private func makePlate() -> SCNNode {
        let plate = SCNBox(
            width: CGFloat(buildVolume.x),
            height: 1,
            length: CGFloat(buildVolume.y),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGray3.withAlphaComponent(0.5)
        material.isDoubleSided = true
        plate.materials = [material]

        let node = SCNNode(geometry: plate)
        node.position = SCNVector3(0, -0.5, 0)
        return node
    }
}

// MARK: - Async loader wrapper

struct ModelPreviewView: View {
    let data: Data?
    let filename: String
    /// Caller-supplied, from the slicing profile or the printer's own
    /// axis limits. The default is a neutral placeholder for previews only -
    /// it is never the size of any real machine.
    var buildVolume: SIMD3<Float> = SIMD3(200, 200, 200)

    @State private var mesh: LoadedMesh?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let mesh {
                ModelViewer3D(mesh: mesh, buildVolume: buildVolume)
            } else if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(localized: "preview.loading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                EmptyStateView(
                    titleKey: "preview.title",
                    messageKey: "preview.select_model",
                    systemImage: "cube.transparent"
                )
            }
        }
        .task(id: filename) { await load() }
    }

    private func load() async {
        guard let data, !data.isEmpty else {
            mesh = nil
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let name = filename
        let result: Result<LoadedMesh, Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try MeshLoader.load(data: data, filename: name))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let loaded):
            mesh = loaded
        case .failure(let error):
            mesh = nil
            errorMessage = error.localizedDescription
        }
    }
}
