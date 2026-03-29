import SwiftUI
import API2FileCore

struct AddServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: IOSAppState

    @State private var templates: [AdapterTemplate] = []
    @State private var selectedTemplate: AdapterTemplate?
    @State private var serviceID = ""
    @State private var apiKey = ""
    @State private var extraFieldValues: [String: String] = [:]
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard

                    if let selectedTemplate {
                        selectedTemplateForm(selectedTemplate)
                    } else {
                        templateLibrary
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, IOSTheme.contentTopInset)
                .padding(.bottom, IOSTheme.contentBottomInset)
            }
            .navigationTitle(selectedTemplate == nil ? "Add Service" : selectedTemplate?.config.displayName ?? "Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selectedTemplate == nil ? "Close" : "Back") {
                        if selectedTemplate == nil {
                            dismiss()
                        } else {
                            selectedTemplate = nil
                        }
                    }
                    .accessibilityIdentifier(selectedTemplate == nil ? "add-service.close" : "add-service.back")
                }

                if selectedTemplate != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isConnecting ? "Connecting..." : "Connect") {
                            Task { await connectSelectedTemplate() }
                        }
                        .disabled(isConnecting || !canConnect)
                        .accessibilityIdentifier("add-service.connect")
                    }
                }
            }
            .task {
                templates = (try? await appState.platformServices.adapterStore.loadAll()) ?? []
            }
            .accessibilityIdentifier(IOSScreenID.addService)
            .iosScreenBackground()
        }
    }

    private var heroCard: some View {
        IOSHeroCard {
            VStack(alignment: .leading, spacing: 16) {
                Text(selectedTemplate == nil ? "Connect a new API workspace" : "Finish the connection")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                Text(
                    selectedTemplate == nil
                        ? "Choose an adapter template, add credentials, and the app will bootstrap a file-based workspace for that service."
                        : "Credentials, service-specific setup fields, and sync folders are created together so the service is ready right away."
                )
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))
            }
        }
    }

    private var templateLibrary: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOSSectionTitle(
                templates.isEmpty ? "Loading templates" : "Available templates",
                eyebrow: "Adapters",
                detail: "Each template defines auth, resource mapping, file formats, and sync rules."
            )

            if templates.isEmpty {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
                    .iosCardStyle()
                    .accessibilityIdentifier("add-service.loading")
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(templates, id: \.config.service) { template in
                        Button {
                            selectedTemplate = template
                            serviceID = template.config.service
                            apiKey = ""
                            extraFieldValues = [:]
                            error = nil
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: template.config.icon ?? "cloud.fill")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 50, height: 50)
                                    .background(IOSTheme.accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(template.config.displayName)
                                        .font(.headline)
                                        .foregroundStyle(IOSTheme.textPrimary)
                                    Text(template.config.wizardDescription ?? template.config.resources.map(\.name).joined(separator: ", "))
                                        .font(.subheadline)
                                        .foregroundStyle(IOSTheme.textSecondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundStyle(IOSTheme.textSecondary)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(IOSAccessibility.id("add-service", "template", template.config.service))
                    }
                }
                .accessibilityIdentifier("add-service.template-list")
            }
        }
    }

    private func selectedTemplateForm(_ selectedTemplate: AdapterTemplate) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            IOSSectionTitle(
                "Connect \(selectedTemplate.config.displayName)",
                eyebrow: "Credentials",
                detail: "The service folder, adapter config, and keychain values will be created together."
            )

            VStack(alignment: .leading, spacing: 14) {
                if let instructions = selectedTemplate.config.auth.setup?.instructions {
                    Text(instructions)
                        .font(.footnote)
                        .foregroundStyle(IOSTheme.textSecondary)
                }

                if selectedTemplate.config.auth.type != .oauth2 {
                    inputField(title: "API Key or Token") {
                        SecureField("Paste key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("add-service.api-key")
                    }
                } else {
                    Text("OAuth sign-in will open your browser.")
                        .font(.footnote)
                        .foregroundStyle(IOSTheme.textSecondary)
                        .accessibilityIdentifier("add-service.oauth-note")
                }

                inputField(title: "Workspace Folder") {
                    TextField("wix-client-a", text: $serviceID)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("add-service.service-id")
                }

                Text("Use a unique folder name when you want multiple connections from the same adapter.")
                    .font(.footnote)
                    .foregroundStyle(IOSTheme.textSecondary)

                ForEach(selectedTemplate.config.setupFields ?? [], id: \.key) { field in
                    inputField(title: field.label) {
                        let placeholder = field.placeholder ?? field.label
                        if field.isSecure == true {
                            SecureField(placeholder, text: binding(for: field.key))
                                .textInputAutocapitalization(.never)
                                .accessibilityIdentifier(IOSAccessibility.id("add-service", "field", field.key))
                        } else {
                            TextField(placeholder, text: binding(for: field.key))
                                .textInputAutocapitalization(.never)
                                .accessibilityIdentifier(IOSAccessibility.id("add-service", "field", field.key))
                        }
                    }
                }

                if let error {
                    Text(error)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(IOSTheme.danger)
                        .accessibilityIdentifier("add-service.error")
                }
            }
            .iosCardStyle()
            .accessibilityIdentifier("add-service.form")
        }
    }

    private func inputField<Content: View>(title: String, @ViewBuilder field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(IOSTheme.textPrimary)

            field()
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var canConnect: Bool {
        guard let selectedTemplate else { return false }
        if selectedTemplate.config.auth.type != .oauth2 && apiKey.isEmpty {
            return false
        }
        if serviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        for field in selectedTemplate.config.setupFields ?? [] where (extraFieldValues[field.key] ?? "").isEmpty {
            return false
        }
        return true
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { extraFieldValues[key] ?? "" },
            set: { extraFieldValues[key] = $0 }
        )
    }

    private func connectSelectedTemplate() async {
        guard let selectedTemplate else { return }
        isConnecting = true
        error = nil

        do {
            try await appState.addService(
                template: selectedTemplate,
                serviceID: serviceID,
                apiKey: apiKey,
                extraFieldValues: extraFieldValues
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }

        isConnecting = false
    }
}
