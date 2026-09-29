//
//  PSUEatsViewController.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 5/16/25.
//


import SwiftUI
import WebKit

class PSUEatsViewController: UIViewController, WKNavigationDelegate {
    private let webView = WKWebView()
    private let urls: [URL]
    private let titles: [String]?
    
    private var backButton: UIBarButtonItem?
    private var forwardButton: UIBarButtonItem?
    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    
    // MARK: - Initializers
    
    init(urls: [URL], titles: [String]?) {
        self.urls = urls
        self.titles = titles
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        
        setupWebView()
        setupNavigationBar()
        setupSegmentedControlIfNeeded()
        registerKeyboardShortcuts()
        segmentedControlValueChanged(nil)
    }
    
    // MARK: - Setup
    
    private func setupWebView() {
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        backObserver = webView.observe(\.canGoBack, options: .new) { [weak self] _, value in
            Task { @MainActor [weak self] in
                self?.backButton?.isEnabled = value.newValue ?? false
            }
        }
        
        forwardObserver = webView.observe(\.canGoForward, options: .new) { [weak self] _, value in
            Task { @MainActor [weak self] in
                self?.forwardButton?.isEnabled = value.newValue ?? false
            }
        }
    }
    
    deinit {
        backObserver?.invalidate()
        forwardObserver?.invalidate()
    }

    private func setupNavigationBar() {
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        
        backButton = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: webView,
            action: #selector(WKWebView.goBack)
        )
        
        forwardButton = UIBarButtonItem(
            image: UIImage(systemName: "chevron.right"),
            style: .plain,
            target: webView,
            action: #selector(WKWebView.goForward)
        )
        
        createNavigationMenu(for: backButton)
        createNavigationMenu(for: forwardButton)
        
        navigationItem.rightBarButtonItems = [forwardButton.unsafelyUnwrapped, backButton.unsafelyUnwrapped]
        
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        self.navigationController?.navigationBar.standardAppearance = appearance;
    }
    
    private func setupSegmentedControlIfNeeded() {
        guard let titles = titles, urls.count > 1 else {
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
            ])
            return
        }
        
        let segmentedControl = UISegmentedControl(items: titles)
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(segmentedControlValueChanged(_:)), for: .valueChanged)
        
        view.addSubview(segmentedControl)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            webView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor)
        ])
    }
    
    // MARK: - Keyboard Shortcuts
    
    private func registerKeyboardShortcuts() {
        let backCommand = UIKeyCommand(
            input: "[",
            modifierFlags: .command,
            action: #selector(WKWebView.goBack)
        )
        backCommand.title = "Go Back"
        
        let forwardCommand = UIKeyCommand(
            input: "]",
            modifierFlags: .command,
            action: #selector(WKWebView.goForward)
        )
        forwardCommand.title = "Go Forward"
        
        addKeyCommand(backCommand)
        addKeyCommand(forwardCommand)
        
        self.backButton?.isEnabled = false
        self.forwardButton?.isEnabled = false
    }
    
    // MARK: - Actions
    @objc private func segmentedControlValueChanged(_ sender: UISegmentedControl?) {
        let selectedURL = urls[sender?.selectedSegmentIndex ?? 0]
        var request = URLRequest(url: selectedURL)
        request.attribution = .user
        
        webView.load(request)
    }
    
    // MARK: - Context Menu
    
    private func createNavigationMenu(for button: UIBarButtonItem?) {
        button?.menu = UIMenu(
            title: "",
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self = self else {
                        completion([])
                        return
                    }

                    let items: [WKBackForwardListItem] =
                    if button == self.backButton {
                        self.webView.backForwardList.backList
                    } else {
                        self.webView.backForwardList.forwardList
                    }

                    let actions = items.map { item in
                        UIAction(title: item.title ?? item.url.absoluteString) { [weak self] _ in
                            self?.webView.go(to: item)
                        }
                    }
                    completion(actions)
                }
            ]
        )
    }
    
    // MARK: - WKNavigationDelegate
    
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationItem.title = webView.title
    }
}

struct WebEatsView: UIViewControllerRepresentable {
    private let urls: [URL]
    private let titles: [String]?

    init(url: URL) {
        self.urls = [url]
        self.titles = nil
    }

    init(urls: [URL], titles: [String]) {
        self.urls = urls
        self.titles = titles
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = PSUEatsViewController(urls: urls, titles: titles)
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

#Preview {
    PSUEatsView(url: URL(string: "https://pennstateeats.psu.edu/1114").unsafelyUnwrapped)
}
