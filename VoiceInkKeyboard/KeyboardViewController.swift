//
//  KeyboardViewController.swift
//  VoiceInkKeyboard
//
//  Created by Prakash Joshi on 28/08/2025.
//

import UIKit
import SwiftUI
import KeyboardKit

class KeyboardViewController: KeyboardInputViewController {
    
    var recordButton: UIButton!
    private var keyboardToggleButton: UIButton!
    private let coordinator = AppGroupCoordinator.shared
    private var recordingStatusTimer: Timer?

    // Set when we've asked the background app to start recording and are
    // waiting for it to confirm; if it never does, the app isn't running
    // and we fall back to opening it once.
    private var pendingStartDeadline: Date?

    // Set when we've asked for a stop and await confirmation; self-heals to
    // idle if the app never confirms (no app-open fallback on stop).
    private var pendingStopDeadline: Date?

    // While set, the 0.5s poll must not overwrite transient message UI
    private var messageHoldUntil: Date?

    // Keyboard extensions can't use NSExtensionContext.open to launch their
    // containing app. When a launch attempt doesn't leave the host, keep an
    // actionable retry state so the next tap tries again directly.
    private var requiresAppLaunch = false

    // The app writes a heartbeat about every 3.5s while it can service
    // background requests. Anything older means we should launch immediately
    // from the user's tap instead of waiting for a request timeout.
    private let appHeartbeatFreshness: TimeInterval = 6.0
    
    deinit {
        recordingStatusTimer?.invalidate()
        recordingStatusTimer = nil
    }
    
    // Height of the top control strip that holds the record + keyboard-toggle
    // buttons (overlaid in UIKit). The expanded keyboard is inset below it.
    private let controlStripHeight: CGFloat = 44

    // Lazy keyboard: default is a compact record bar that opens instantly.
    // The full QWERTY (KeyboardKit's `KeyboardView`) is only rendered when the
    // user taps the keyboard-toggle button to edit dictated text. Building the
    // full `SystemKeyboard` on every open was the source of the open-lag.
    private var isKeyboardExpanded = false

    override func viewWillSetupKeyboardView() {
        installKeyboardView()
    }

    // Swaps the SwiftUI content between the compact placeholder and the full
    // keyboard. Safe to call again at runtime to toggle expansion.
    private func installKeyboardView() {
        if isKeyboardExpanded {
            let stripHeight = controlStripHeight
            setupKeyboardView { controller in
                // Reuse KeyboardView's toolbar slot as the control strip the
                // UIKit record/toggle buttons overlay. This avoids stacking a
                // separate strip ON TOP of the (empty) autocomplete toolbar,
                // which was the source of the large gap above the keys.
                KeyboardView(
                    state: controller.state,
                    services: controller.services,
                    buttonContent: { $0.view },
                    buttonView: { $0.view },
                    collapsedView: { $0.view },
                    emojiKeyboard: { $0.view },
                    toolbar: { _ in Color.clear.frame(height: stripHeight) }
                )
            }
        } else {
            let stripHeight = controlStripHeight
            setupKeyboardView { _ in
                Color.clear.frame(height: stripHeight)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupKeyboard()
        setupRecordingStatusMonitoring()

        // Insert the transcript the moment the main app publishes it
        coordinator.onTranscriptionReady = { [weak self] in
            self?.insertPendingTranscriptIfAvailable()
            self?.updateButtonAppearanceBasedOnState()
        }

        // Positive acks via Darwin notifications: instant confirmation that
        // works even when the shared container is unreadable on our side
        coordinator.onRecordingDidStart = { [weak self] in
            guard let self else { return }
            self.pendingStartDeadline = nil
            self.messageHoldUntil = nil
            self.requiresAppLaunch = false
            self.configureButtonForRecordingState()
        }

        coordinator.onRecordingDidStop = { [weak self] in
            guard let self else { return }
            self.pendingStopDeadline = nil
            self.configureButtonForProcessingState()
        }

        coordinator.onStartRecordingFailed = { [weak self] in
            guard let self else { return }
            self.pendingStartDeadline = nil
            self.pendingStopDeadline = nil
            self.showTransientMessage(" Mic unavailable", symbol: "mic.slash")
        }

        // Pick up any transcript that finished while the keyboard was closed
        if hasFullAccess {
            insertPendingTranscriptIfAvailable()
        } else {
            configureButtonForNoAccessState()
        }
    }
    
    private func setupKeyboard() {
        // Setup KeyboardKit with default configuration
        setupKeyboardKit()

        // Add our custom record button at the top
        setupRecordButton()

        // Add the keyboard-toggle button next to the record button
        setupKeyboardToggleButton()
    }

    private func setupKeyboardToggleButton() {
        keyboardToggleButton = UIButton(type: .system)
        keyboardToggleButton.translatesAutoresizingMaskIntoConstraints = false
        keyboardToggleButton.addTarget(self, action: #selector(keyboardToggleTapped), for: .touchUpInside)
        keyboardToggleButton.backgroundColor = UIColor.secondarySystemBackground
        keyboardToggleButton.tintColor = .label
        keyboardToggleButton.layer.borderWidth = 0.5
        keyboardToggleButton.layer.borderColor = UIColor.separator.cgColor

        view.addSubview(keyboardToggleButton)
        NSLayoutConstraint.activate([
            keyboardToggleButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            keyboardToggleButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            keyboardToggleButton.heightAnchor.constraint(equalToConstant: 32),
            keyboardToggleButton.widthAnchor.constraint(equalToConstant: 40)
        ])

        updateKeyboardToggleAppearance()
    }

    private func updateKeyboardToggleAppearance() {
        guard let button = keyboardToggleButton else { return }
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let symbol = isKeyboardExpanded ? "keyboard.chevron.compact.down" : "keyboard"
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.layer.cornerRadius = 16
    }

    @objc private func keyboardToggleTapped() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()

        isKeyboardExpanded.toggle()
        installKeyboardView()
        updateKeyboardToggleAppearance()

        // Keep the overlay controls on top of the freshly-installed view
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let b = self.recordButton { self.view.bringSubviewToFront(b) }
            if let t = self.keyboardToggleButton { self.view.bringSubviewToFront(t) }
        }
    }
    
    private func setupKeyboardKit() {
        // KeyboardInputViewController automatically sets up the keyboard
        // We can customize the keyboard appearance here if needed
        
        // Make the keyboard more compact
        setupCompactKeyboard()
    }
    
    private func setupCompactKeyboard() {
        // Customize KeyboardKit's key styling to make keys more compact
        // This requires working with KeyboardKit's styling system
        
        // Note: KeyboardKit's styling is complex and may require KeyboardKit Pro
        // For now, we'll keep the default keyboard layout
        // Individual key customization would require:
        // 1. Custom KeyboardStyleProvider
        // 2. Custom KeyboardLayoutProvider  
        // 3. Overriding key button styles
        
    }
    
    private func setupRecordButton() {
        // Create the native iOS-style record button
        recordButton = UIButton(type: .system)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addTarget(self, action: #selector(recordButtonTapped), for: .touchUpInside)
        
        // Configure for idle state initially
        configureButtonForIdleState()
        
        // Add native iOS styling
        recordButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        recordButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        
        // Native iOS shadow and styling
        recordButton.layer.shadowColor = UIColor.black.cgColor
        recordButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        recordButton.layer.shadowOpacity = 0.2
        recordButton.layer.shadowRadius = 2
        
        // Add subtle border for better definition
        recordButton.layer.borderWidth = 0.5
        recordButton.layer.borderColor = UIColor.separator.cgColor
        
        // Add button to main view
        view.addSubview(recordButton)
        
        // Pin the record button to the LEFT edge so it's far from the
        // keyboard-toggle button on the right (avoids mis-taps).
        NSLayoutConstraint.activate([
            recordButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            recordButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            recordButton.heightAnchor.constraint(equalToConstant: 32),
            recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        
        // Ensure button stays on top
        view.bringSubviewToFront(recordButton)
    }
    
    private func configureButtonForIdleState() {
        // Use SF Symbol for microphone
        let microphoneConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let microphoneImage = UIImage(systemName: "mic.fill", withConfiguration: microphoneConfig)
        
        recordButton.setImage(microphoneImage, for: .normal)
        recordButton.setTitle(" Record", for: .normal)
        recordButton.backgroundColor = UIColor.systemBlue
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        
        // Ensure image and text are properly aligned
        recordButton.semanticContentAttribute = .forceLeftToRight
        recordButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        recordButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
    }
    
    private func configureButtonForRecordingState() {
        // Use SF Symbol for stop
        let stopConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let stopImage = UIImage(systemName: "stop.fill", withConfiguration: stopConfig)
        
        recordButton.setImage(stopImage, for: .normal)
        recordButton.setTitle(" Stop", for: .normal)
        recordButton.backgroundColor = UIColor.systemRed
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
        
        // Ensure image and text are properly aligned
        recordButton.semanticContentAttribute = .forceLeftToRight
        recordButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        recordButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Re-add and ensure record button stays on top after KeyboardKit layout
        if let button = recordButton {
            if button.superview == nil {
                view.addSubview(button)
            }
            view.bringSubviewToFront(button)

            // Ensure proper capsule shape after layout
            DispatchQueue.main.async {
                button.layer.cornerRadius = button.frame.height / 2
            }
        } else {
            // no-op
        }

        if let toggle = keyboardToggleButton {
            if toggle.superview == nil { view.addSubview(toggle) }
            view.bringSubviewToFront(toggle)
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Re-add button if KeyboardKit removed it
        if let button = recordButton, button.superview == nil {
            view.addSubview(button)
        }
        
        // Ensure button is still visible after layout
        if let button = recordButton {
            view.bringSubviewToFront(button)

            // Make button fully capsule-shaped based on its actual height
            button.layer.cornerRadius = button.frame.height / 2
        }

        // Keyboard-toggle button also stays on top of the installed view
        if let toggle = keyboardToggleButton {
            if toggle.superview == nil { view.addSubview(toggle) }
            view.bringSubviewToFront(toggle)
        }
    }
    
    @objc private func recordButtonTapped() {
        // Add native iOS button press animation
        addButtonPressAnimation()
        
        // Provide haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        
        // Without Full Access the shared container is silently isolated and
        // the pipeline cannot work - tell the user instead of misbehaving
        guard hasFullAccess else {
            configureButtonForNoAccessState()
            return
        }

        if requiresAppLaunch {
            requiresAppLaunch = false
            openMainAppForRecording()
            return
        }

        if coordinator.isRecording || pendingStopDeadline != nil {
            // Stop already requested - ignore re-taps while waiting
            guard pendingStopDeadline == nil else { return }
            // Stop recording; the main app will transcribe and publish the text
            coordinator.requestStopRecording()
            pendingStopDeadline = Date().addingTimeInterval(2.0)
            configureButtonForProcessingState()
        } else if coordinator.isProcessing && coordinator.processingAge < 120 {
            // Transcription in flight - ignore taps
        } else if pendingStartDeadline != nil {
            // Start already requested - ignore re-taps while waiting
        } else {
            if coordinator.appHeartbeatAge > appHeartbeatFreshness {
                // The app is not scheduled (force-quit, killed, or hibernated).
                // Launch while this call is still tied to the button tap.
                openMainAppForRecording()
            } else {
                // The background-resident app should be able to start without
                // disrupting the host app. If it doesn't acknowledge the
                // request, the timeout below launches it as a fallback.
                coordinator.requestStartRecording()
                pendingStartDeadline = Date().addingTimeInterval(2.0)
                configureButtonForStartingState()
            }
        }
    }
    
    private func addButtonPressAnimation() {
        // Native iOS button press animation - scale down then back up
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseInOut], animations: {
            self.recordButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseInOut], animations: {
                self.recordButton.transform = CGAffineTransform.identity
            })
        }
    }
    
    private func openMainAppForRecording() {
        coordinator.appendDiag("KB: FALLBACK - opening main app (no confirmation, heartbeatAge=\(Int(coordinator.appHeartbeatAge)))")
        guard let url = URL(string: "voiceink://record") else {
            showUserMessage()
            return
        }

        configureButtonForStartingState()
        messageHoldUntil = Date().addingTimeInterval(1.5)

        // NSExtensionContext.open is not supported for custom keyboards.
        // KeyboardKit's URL opener uses the modern responder-chain scene/app
        // API that its KeyboardInputViewController provides for this purpose.
        openUrl(url)

        // If the keyboard is still visible, opening failed. Leave a persistent
        // action the user can tap to retry instead of silently returning idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil,
                  !self.coordinator.isRecording else { return }
            self.coordinator.appendDiag("KB: main-app launch did not leave host")
            self.showUserMessage()
        }
    }

    private func configureButtonForOpenAppState() {
        let appConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let appImage = UIImage(systemName: "app", withConfiguration: appConfig)

        recordButton.setImage(appImage, for: .normal)
        recordButton.setTitle(" Open VoiceInk", for: .normal)
        recordButton.backgroundColor = UIColor.systemOrange
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
    }

    private func showUserMessage() {
        requiresAppLaunch = true
        messageHoldUntil = nil
        configureButtonForOpenAppState()
    }
    
    private func setupRecordingStatusMonitoring() {
        // Monitor recording status every 0.5 seconds
        recordingStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateButtonAppearanceBasedOnState()
        }
        
        // Initial state update
        updateButtonAppearanceBasedOnState()
    }
    
    private func updateButtonAppearanceBasedOnState() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.recordButton else { return }

            // Full Access off: pipeline can't work, show the persistent hint
            // (this gate must live here too or the poll would clobber it)
            guard self.hasFullAccess else {
                self.pendingStartDeadline = nil
                self.pendingStopDeadline = nil
                self.configureButtonForNoAccessState()
                button.layer.cornerRadius = button.frame.height / 2
                return
            }

            // Don't clobber a transient message the user should read
            if let holdUntil = self.messageHoldUntil {
                if Date() < holdUntil { return }
                self.messageHoldUntil = nil
            }

            // Insert any transcript the main app has published
            self.insertPendingTranscriptIfAvailable()

            let isRecording = self.coordinator.isRecording
            let isProcessing = self.coordinator.isProcessing

            if let deadline = self.pendingStopDeadline {
                // Waiting for stop confirmation; self-heal if it never comes
                if Date() > deadline {
                    self.pendingStopDeadline = nil
                    self.configureButtonForIdleState()
                } else {
                    self.configureButtonForProcessingState()
                }
            } else if isRecording {
                // Main app confirmed recording started
                self.pendingStartDeadline = nil
                self.requiresAppLaunch = false
                self.configureButtonForRecordingState()
            } else if let deadline = self.pendingStartDeadline {
                if Date() > deadline {
                    // App never confirmed - it isn't running. Open it once.
                    self.pendingStartDeadline = nil
                    self.openMainAppForRecording()
                } else {
                    self.configureButtonForStartingState()
                }
            } else if isProcessing {
                self.configureButtonForProcessingState()
            } else if self.requiresAppLaunch {
                self.configureButtonForOpenAppState()
            } else {
                self.configureButtonForIdleState()
            }

            // Ensure capsule shape is maintained
            button.layer.cornerRadius = button.frame.height / 2
        }
    }

    private func configureButtonForNoAccessState() {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = UIImage(systemName: "lock.open", withConfiguration: config)

        recordButton.setImage(image, for: .normal)
        recordButton.setTitle(" Enable Full Access", for: .normal)
        recordButton.backgroundColor = UIColor.systemOrange
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
    }

    private func showTransientMessage(_ title: String, symbol: String) {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = UIImage(systemName: symbol, withConfiguration: config)

        recordButton.setImage(image, for: .normal)
        recordButton.setTitle(title, for: .normal)
        recordButton.backgroundColor = UIColor.systemOrange
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white

        messageHoldUntil = Date().addingTimeInterval(2.5)
    }

    private func insertPendingTranscriptIfAvailable() {
        guard let text = coordinator.consumePendingTranscript() else { return }
        textDocumentProxy.insertText(text)

        let notificationFeedback = UINotificationFeedbackGenerator()
        notificationFeedback.notificationOccurred(.success)
    }

    private func configureButtonForStartingState() {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = UIImage(systemName: "mic.badge.plus", withConfiguration: config)

        recordButton.setImage(image, for: .normal)
        recordButton.setTitle(" Starting…", for: .normal)
        recordButton.backgroundColor = UIColor.systemGray
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
    }

    private func configureButtonForProcessingState() {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = UIImage(systemName: "waveform", withConfiguration: config)

        recordButton.setImage(image, for: .normal)
        recordButton.setTitle(" Transcribing…", for: .normal)
        recordButton.backgroundColor = UIColor.systemGray
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.tintColor = .white
    }
    
    override func textWillChange(_ textInput: UITextInput?) {
        // The app is about to change the document's contents
        super.textWillChange(textInput)
    }
    
    override func textDidChange(_ textInput: UITextInput?) {
        // The app has just changed the document's contents
        super.textDidChange(textInput)
    }
}
