import SwiftUI

struct ModeConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    @StateObject private var catalog = ModelCatalog.shared

    @State private var mode: Mode
    @State private var isEditing: Bool
    @State private var selectedTemplateType: PromptTemplateType
    @State private var customPromptText: String
    
    let onSave: (Mode) -> Void
    
    init(mode: Mode? = nil, settings: AppSettings, onSave: @escaping (Mode) -> Void) {
        self.settings = settings
        self.onSave = onSave
        self.isEditing = mode != nil
        let initialMode = mode ?? Mode(name: "")
        self._mode = State(initialValue: initialMode)
        self._selectedTemplateType = State(initialValue: initialMode.promptTemplate.type)
        self._customPromptText = State(initialValue: initialMode.promptTemplate.customPrompt)
    }
    
    /// Available transcription providers (those with valid API keys or downloaded local models)
    private var availableTranscriptionProviders: [Provider] {
        Provider.allCases.filter { provider in
            // VoiceInk is always available (has hardcoded API key)
            if provider == .voiceink {
                return true
            }
            // Other providers: Must have models for transcription AND be properly configured
            return !catalog.models(for: provider, type: .transcription).isEmpty && settings.isKeyVerified(for: provider)
        }
    }
    
    /// Available post-processing providers (those with valid API keys)
    private var availablePostProcessingProviders: [Provider] {
        Provider.allCases.filter { provider in
            // VoiceInk is always available (has hardcoded API key)
            if provider == .voiceink {
                return true
            }
            // Other providers: Must have models for post-processing AND be properly configured
            return !catalog.models(for: provider, type: .postProcessing).isEmpty && settings.isKeyVerified(for: provider)
        }
    }
    
    var body: some View {
        Form {
            Section(header: Text("Mode Details")) {
                TextField("Mode Name", text: $mode.name)
                    .textInputAutocapitalization(.words)
            }
            
            Section(header: Text("Transcription")) {
                Picker("Provider", selection: $mode.transcriptionProvider) {
                    ForEach(availableTranscriptionProviders) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                
                if mode.transcriptionProvider != .voiceink {
                    Picker("Model", selection: $mode.transcriptionModel) {
                        ForEach(modelOptions(for: mode.transcriptionProvider, type: .transcription, current: mode.transcriptionModel), id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                } else {
                    HStack {
                        Text("Model")
                        Spacer()
                        Text("whisper-large-v3")
                            .foregroundColor(.secondary)
                    }
                }

                Picker("Language", selection: $mode.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.all) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            }
            
            Section(header: Text("Post-processing"), 
                   footer: mode.isPostProcessingEnabled ? Text("Configure how the raw transcription should be processed and refined.") : nil) {
                Toggle("Enable Post-processing", isOn: $mode.isPostProcessingEnabled)
                
                if mode.isPostProcessingEnabled {
                    Picker("Provider", selection: $mode.postProcessingProvider) {
                        ForEach(availablePostProcessingProviders) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    
                    if mode.postProcessingProvider != .voiceink {
                        Picker("Model", selection: $mode.postProcessingModel) {
                            ForEach(modelOptions(for: mode.postProcessingProvider, type: .postProcessing, current: mode.postProcessingModel), id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    } else {
                        HStack {
                            Text("Model")
                            Spacer()
                            Text("gpt-oss-120b")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Prompt Template Selection
                    Picker("Prompt Template", selection: $selectedTemplateType) {
                        ForEach(PromptTemplateType.allCases, id: \.self) { templateType in
                            Text(templateType.displayName).tag(templateType)
                        }
                    }
                    
                    // Show custom prompt field only when Custom is selected
                    if selectedTemplateType == .custom {
                        TextField("Custom Prompt", text: $customPromptText, axis: .vertical)
                            .lineLimit(4, reservesSpace: true)
                    }
                }
            }

            if mode.isPostProcessingEnabled {
                Section(header: Text("Fallback Models"),
                        footer: Text("Tried in order when the primary model fails or times out. Cross-provider fallbacks survive a whole-provider outage.")) {
                    ForEach(fallbacks.indices, id: \.self) { index in
                        fallbackRow(at: index)
                    }
                    .onDelete { offsets in
                        var list = fallbacks
                        list.remove(atOffsets: offsets)
                        mode.postProcessingFallbacks = list.isEmpty ? nil : list
                    }

                    if fallbacks.count < 3 {
                        Button("Add Fallback Model") {
                            addFallback()
                        }
                    }
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Mode" : "New Mode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    // Update the mode's prompt template before saving
                    mode.promptTemplate = PromptTemplate(type: selectedTemplateType, customPrompt: customPromptText)
                    onSave(mode)
                    dismiss()
                }
                .disabled(mode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || 
                         (selectedTemplateType == .custom && customPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .task {
            // Refresh model lists from provider APIs for all verified providers
            for provider in Provider.allCases where settings.isKeyVerified(for: provider) {
                await catalog.refresh(provider)
            }
        }
        .onChange(of: mode.transcriptionProvider) { _, newProvider in
            // Update model when provider changes
            if newProvider == .voiceink {
                mode.transcriptionModel = settings.voiceInkTranscriptionModel()
            } else {
                Task {
                    await catalog.refresh(newProvider)
                    let availableModels = catalog.models(for: newProvider, type: .transcription)
                    if !availableModels.contains(mode.transcriptionModel) {
                        mode.transcriptionModel = availableModels.first ?? ""
                    }
                }
            }
        }
        .onChange(of: mode.postProcessingProvider) { _, newProvider in
            // Update model when provider changes
            if newProvider == .voiceink {
                mode.postProcessingModel = settings.voiceInkPostProcessingModel()
            } else {
                Task {
                    await catalog.refresh(newProvider)
                    let availableModels = catalog.models(for: newProvider, type: .postProcessing)
                    if !availableModels.contains(mode.postProcessingModel) {
                        mode.postProcessingModel = availableModels.first ?? ""
                    }
                }
            }
        }
    }

    /// Model list from the catalog, keeping the mode's saved model selectable
    /// even if it no longer appears in the fetched list.
    private func modelOptions(for provider: Provider, type: ModelType, current: String) -> [String] {
        var models = catalog.models(for: provider, type: type)
        if !current.isEmpty && !models.contains(current) {
            models.insert(current, at: 0)
        }
        return models
    }

    // MARK: - Post-processing fallbacks

    private var fallbacks: [PostProcessingFallback] {
        mode.postProcessingFallbacks ?? []
    }

    private func fallbackBinding(at index: Int) -> Binding<PostProcessingFallback> {
        Binding(
            get: {
                let list = fallbacks
                guard index < list.count else { return PostProcessingFallback(provider: .groq, model: "") }
                return list[index]
            },
            set: { newValue in
                var list = fallbacks
                guard index < list.count else { return }
                list[index] = newValue
                mode.postProcessingFallbacks = list
            }
        )
    }

    @ViewBuilder
    private func fallbackRow(at index: Int) -> some View {
        let binding = fallbackBinding(at: index)
        // Provider changes reset the model inside the setter (not onChange):
        // index-based onChange misfires when a deleted row shifts indices,
        // clobbering an unrelated row's saved model
        let providerBinding = Binding<Provider>(
            get: { binding.wrappedValue.provider },
            set: { newProvider in
                guard newProvider != binding.wrappedValue.provider else { return }
                binding.wrappedValue = PostProcessingFallback(provider: newProvider, model: defaultModel(for: newProvider))
            }
        )
        VStack {
            Picker("Fallback \(index + 1)", selection: providerBinding) {
                ForEach(availablePostProcessingProviders) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }

            if binding.wrappedValue.provider == .voiceink {
                HStack {
                    Text("Model")
                    Spacer()
                    Text(settings.voiceInkPostProcessingModel())
                        .foregroundColor(.secondary)
                }
            } else {
                Picker("Model", selection: binding.model) {
                    ForEach(modelOptions(for: binding.wrappedValue.provider, type: .postProcessing, current: binding.wrappedValue.model), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }
        }
    }

    private func addFallback() {
        // Prefer a provider different from the primary so the fallback
        // survives a provider outage
        let provider = availablePostProcessingProviders.first { $0 != mode.postProcessingProvider }
            ?? mode.postProcessingProvider
        var list = fallbacks
        list.append(PostProcessingFallback(provider: provider, model: defaultModel(for: provider)))
        mode.postProcessingFallbacks = list
    }

    private func defaultModel(for provider: Provider) -> String {
        if provider == .voiceink {
            return settings.voiceInkPostProcessingModel()
        }
        return catalog.models(for: provider, type: .postProcessing).first
            ?? provider.models(for: .postProcessing).first
            ?? ""
    }
}

#Preview {
    ModeConfigurationView(settings: AppSettings.shared) { _ in }
}