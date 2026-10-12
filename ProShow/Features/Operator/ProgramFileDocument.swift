import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
/// Standalone `.program` bundle document for Rundown Studio.
struct ProgramFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.proShowProgram, .json] }
    static var writableContentTypes: [UTType] { [.proShowProgram] }

    var model: ProgramDocumentModel

    init(model: ProgramDocumentModel = .sundayMorningSample()) {
        self.model = model
    }

    init(configuration: ReadConfiguration) throws {
        if let wrapper = configuration.file.fileWrappers?[ProgramDocumentFormat.jsonFilename],
           let data = wrapper.regularFileContents {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            model = try decoder.decode(ProgramDocumentModel.self, from: data)
            return
        }
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        model = try decoder.decode(ProgramDocumentModel.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(model)
        let json = FileWrapper(regularFileWithContents: data)
        json.preferredFilename = ProgramDocumentFormat.jsonFilename
        return FileWrapper(directoryWithFileWrappers: [ProgramDocumentFormat.jsonFilename: json])
    }
}
struct ProgramRundownStandaloneRoot: View {
    @State private var controller = ShowController.bootstrap()
    var model: ProgramDocumentModel

    var body: some View {
        RundownWorkspaceView(controller: controller)
            .onAppear {
                controller.setMode(.rundown)
                controller.loadProgramDocument(model)
            }
    }
}
#endif
