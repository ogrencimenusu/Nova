import UIKit
import Social
import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

struct SharedAttachment: Identifiable {
    let id = UUID()
    let fileName: String
    let fileData: Data
    let mimeType: String
}

// MARK: - Smart Receipt Parser for Turkish Banks
struct ParsedReceiptResult {
    let bankId: String?
    let bankName: String?
    let amount: String?
}

enum ReceiptParseState: Equatable {
    case idle
    case parsing
    case success(bankName: String, amount: String)
    case failed
}

func normalizeTurkishSearch(_ text: String) -> String {
    return text
        .replacingOccurrences(of: "İ", with: "i")
        .replacingOccurrences(of: "I", with: "ı")
        .replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "ş", with: "s")
        .replacingOccurrences(of: "Ş", with: "s")
        .replacingOccurrences(of: "ğ", with: "g")
        .replacingOccurrences(of: "Ğ", with: "g")
        .replacingOccurrences(of: "ü", with: "u")
        .replacingOccurrences(of: "Ü", with: "u")
        .replacingOccurrences(of: "ö", with: "o")
        .replacingOccurrences(of: "Ö", with: "o")
        .replacingOccurrences(of: "ç", with: "c")
        .replacingOccurrences(of: "Ç", with: "c")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

class SmartReceiptParser {
    static func parse(data: Data, mimeType: String, banks: [CachedBank]) -> ParsedReceiptResult {
        var rawText = ""
        
        // 1. Extract text via PDFKit
        if let pdfDoc = PDFDocument(data: data) {
            for i in 0..<pdfDoc.pageCount {
                if let page = pdfDoc.page(at: i), let str = page.string {
                    rawText += "\n" + str
                }
            }
        }
        
        // 2. Fallback text extraction
        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                rawText = str
            }
        }
        
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ParsedReceiptResult(bankId: nil, bankName: nil, amount: nil)
        }
        
        let normText = normalizeTurkishSearch(rawText)
        
        // A. Identify Bank
        var detectedKey: String? = nil
        var detectedDisplayName: String? = nil
        
        if normText.contains("vakifbank") || normText.contains("vakiflar bankasi") {
            detectedKey = "vakif"
            detectedDisplayName = "Vakıfbank"
        } else if normText.contains("turkiye is bankasi") || normText.contains("is bankasi") || normText.contains("isbank.com.tr") || normText.contains("iscep") || normText.contains("isbank") || normText.contains("e-dekont") {
            detectedKey = "isbank"
            detectedDisplayName = "İş Bankası"
        } else if normText.contains("akbank") || normText.contains("odeme emri cikisi") {
            detectedKey = "akbank"
            detectedDisplayName = "Akbank"
        } else {
            // Check other banks in user's bank list
            for b in banks {
                let bNorm = normalizeTurkishSearch(b.name)
                if bNorm.count >= 3 && normText.contains(bNorm) {
                    detectedKey = b.id
                    detectedDisplayName = b.name
                    break
                }
            }
        }
        
        // Match with CachedBank ID using Turkish-safe normalization
        var matchedBankId: String? = nil
        if let key = detectedKey {
            if key == "vakif" {
                matchedBankId = banks.first(where: {
                    let n = normalizeTurkishSearch($0.name)
                    return n.contains("vakif")
                })?.id
            } else if key == "isbank" {
                matchedBankId = banks.first(where: {
                    let n = normalizeTurkishSearch($0.name)
                    return n.contains("is") || n.contains("isbank")
                })?.id
            } else if key == "akbank" {
                matchedBankId = banks.first(where: {
                    let n = normalizeTurkishSearch($0.name)
                    return n.contains("akbank")
                })?.id
            } else {
                matchedBankId = banks.first(where: { $0.id == key })?.id
            }
        }
        
        // B. Extract Amount
        var extractedAmount: String? = nil
        
        if detectedKey == "vakif" {
            let patterns = [
                #"(?:İŞLEM\s+TUTARI|ISLEM\s+TUTARI|TUTARI|TUTAR)\s*[:]?\s*([0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]{2})|[0-9]+(?:,[0-9]{2}))"#,
                #"([0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]{2}))\s*(?:TL|TRY)"#
            ]
            for pat in patterns {
                if let amt = matchRegex(pattern: pat, in: rawText) {
                    extractedAmount = amt
                    break
                }
            }
        } else if detectedKey == "isbank" {
            let patterns = [
                #"(?:Aktarılan\s+Tutar|Toplam\s+Tutar|AKTARILAN\s+TUTAR|TOPLAM\s+TUTAR|Tutar)\s*[:]?\s*([0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]{2})|[0-9]+(?:,[0-9]{2}))"#,
                #"([0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]{2}))\s*(?:TRY|TL)"#
            ]
            for pat in patterns {
                if let amt = matchRegex(pattern: pat, in: rawText) {
                    extractedAmount = amt
                    break
                }
            }
        } else if detectedKey == "akbank" {
            let patterns = [
                #"(?:TOPLAM|Toplam)\s*[:]?\s*([0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]{2})|[0-9]+(?:,[0-9]{2}))\s*(?:TL|TRY)"#,
                #"(?:MEVDUAT|ŞCH|SCH).*?([1-9][0-9]{0,2}(?:\.[0-9]{3})*(?:,[0-9]{2}))\s*TL"#,
                #"([0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]{2}))\s*TL"#
            ]
            for pat in patterns {
                if let amt = matchRegex(pattern: pat, in: rawText) {
                    extractedAmount = amt
                    break
                }
            }
        } else {
            let genericPatterns = [
                #"(?:Toplam\s+Tutar|İşlem\s+Tutarı|Tutar|TUTAR)\s*[:]?\s*([0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]{2})|[0-9]+(?:,[0-9]{2}))"#,
                #"([0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]{2}))\s*(?:TL|TRY)"#
            ]
            for pat in genericPatterns {
                if let amt = matchRegex(pattern: pat, in: rawText) {
                    extractedAmount = amt
                    break
                }
            }
        }
        
        return ParsedReceiptResult(bankId: matchedBankId, bankName: detectedDisplayName, amount: extractedAmount)
    }
    
    private static func matchRegex(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsString = text as NSString
        let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        for match in results {
            if match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if range.location != NSNotFound {
                    return nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }
}

// MARK: - ShareViewController
class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemGroupedBackground
        
        // Safe Firebase configuration
        if FirebaseApp.app() == nil {
            if let plistPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")
                ?? Bundle(for: ShareViewController.self).path(forResource: "GoogleService-Info", ofType: "plist"),
               let options = FirebaseOptions(contentsOfFile: plistPath) {
                FirebaseApp.configure(options: options)
            }
        }

        // Share Keychain credentials with main app
        let accessGroup = "A64NZ37MJD.group.sakyol.nova"
        try? Auth.auth().useUserAccessGroup(accessGroup)

        setupSwiftUIView()
    }

    private func setupSwiftUIView() {
        extractSharedItems { [weak self] attachments in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                let formView = ShareTransactionFormView(attachments: attachments) { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                } onCancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(withError: NSError(domain: "UserCancelled", code: 0))
                }

                let hostingVC = UIHostingController(rootView: formView)
                self.addChild(hostingVC)
                hostingVC.view.translatesAutoresizingMaskIntoConstraints = false
                self.view.addSubview(hostingVC.view)
                
                NSLayoutConstraint.activate([
                    hostingVC.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                    hostingVC.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
                    hostingVC.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                    hostingVC.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
                ])
                
                hostingVC.didMove(toParent: self)
            }
        }
    }

    private func extractSharedItems(completion: @escaping ([SharedAttachment]) -> Void) {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var results: [SharedAttachment] = []
        var itemCounter = 1

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                group.enter()
                
                loadAttachment(from: provider, itemIndex: itemCounter) { att in
                    if let att = att {
                        lock.lock()
                        results.append(att)
                        itemCounter += 1
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(results)
        }
    }

    private func loadAttachment(from provider: NSItemProvider, itemIndex: Int, completion: @escaping (SharedAttachment?) -> Void) {
        let registered = provider.registeredTypeIdentifiers
        guard !registered.isEmpty else {
            completion(nil)
            return
        }

        // Prioritize specific document types (Word, PDF, Images, Excel)
        var typeToLoad = registered.first!
        for r in registered {
            let lower = r.lowercased()
            if lower.contains("word") || lower.contains("openxmlformats") || lower.contains("doc") {
                typeToLoad = r
                break
            } else if lower.contains("pdf") {
                typeToLoad = r
                break
            } else if lower.contains("image") || lower.contains("jpeg") || lower.contains("png") {
                typeToLoad = r
                break
            } else if lower.contains("sheet") || lower.contains("excel") {
                typeToLoad = r
                break
            }
        }

        // 1. Try loadItem with selected UTI
        provider.loadItem(forTypeIdentifier: typeToLoad, options: nil) { [weak self] itemData, error in
            guard let self = self else {
                completion(nil)
                return
            }

            if let att = self.parseAttachment(itemData: itemData, typeIdentifier: typeToLoad, itemIndex: itemIndex) {
                completion(att)
            } else {
                // 2. Fallback: try loadFileRepresentation for file-based providers
                provider.loadFileRepresentation(forTypeIdentifier: typeToLoad) { url, err in
                    if let url = url, let att = self.parseAttachment(itemData: url, typeIdentifier: typeToLoad, itemIndex: itemIndex) {
                        completion(att)
                    } else if registered.count > 1, let alternateType = registered.first(where: { $0 != typeToLoad }) {
                        // 3. Fallback: try secondary registered UTI
                        provider.loadItem(forTypeIdentifier: alternateType, options: nil) { itemData2, _ in
                            completion(self.parseAttachment(itemData: itemData2, typeIdentifier: alternateType, itemIndex: itemIndex))
                        }
                    } else {
                        completion(nil)
                    }
                }
            }
        }
    }

    private func parseAttachment(itemData: Any?, typeIdentifier: String, itemIndex: Int) -> SharedAttachment? {
        guard let itemData = itemData else { return nil }

        var fileName: String? = nil
        var fileData: Data? = nil
        var mimeType: String = "application/octet-stream"

        if let url = itemData as? URL {
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

            if let data = try? Data(contentsOf: url), !data.isEmpty {
                fileData = data
                fileName = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                if let uti = UTType(filenameExtension: ext), let prefMime = uti.preferredMIMEType {
                    mimeType = prefMime
                } else if ext == "pdf" {
                    mimeType = "application/pdf"
                } else if ext == "docx" {
                    mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                } else if ext == "doc" {
                    mimeType = "application/msword"
                } else if ext == "png" {
                    mimeType = "image/png"
                } else if ext == "jpg" || ext == "jpeg" {
                    mimeType = "image/jpeg"
                }
            }
        } else if let image = itemData as? UIImage {
            if let data = image.jpegData(compressionQuality: 0.85) {
                fileData = data
                fileName = "Görsel_\(itemIndex).jpg"
                mimeType = "image/jpeg"
            }
        } else if let data = itemData as? Data, !data.isEmpty {
            fileData = data
            let lowerType = typeIdentifier.lowercased()

            if lowerType.contains("word") || lowerType.contains("openxmlformats") || lowerType.contains("doc") {
                let isDocx = lowerType.contains("openxmlformats") || lowerType.contains("docx")
                mimeType = isDocx ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document" : "application/msword"
                fileName = "Dekont_\(itemIndex).\(isDocx ? "docx" : "doc")"
            } else if lowerType.contains("pdf") || (data.count > 4 && data.prefix(4) == Data([0x25, 0x50, 0x44, 0x46])) {
                mimeType = "application/pdf"
                fileName = "Dekont_\(itemIndex).pdf"
            } else if lowerType.contains("image") || lowerType.contains("png") || lowerType.contains("jpeg") {
                mimeType = lowerType.contains("png") ? "image/png" : "image/jpeg"
                fileName = "Dekont_\(itemIndex).\(lowerType.contains("png") ? "png" : "jpg")"
            } else {
                if let uti = UTType(typeIdentifier), let ext = uti.preferredFilenameExtension, let prefMime = uti.preferredMIMEType {
                    mimeType = prefMime
                    fileName = "Belge_\(itemIndex).\(ext)"
                } else {
                    mimeType = "application/pdf"
                    fileName = "Dekont_\(itemIndex).pdf"
                }
            }
        }

        guard let validData = fileData, !validData.isEmpty else { return nil }
        let validName = (fileName != nil && !fileName!.isEmpty) ? fileName! : "Belge_\(itemIndex).pdf"
        return SharedAttachment(fileName: validName, fileData: validData, mimeType: mimeType)
    }
}

// MARK: - SwiftUI Form View
struct ShareTransactionFormView: View {
    @State var attachments: [SharedAttachment]
    var onDone: () -> Void
    var onCancel: () -> Void

    // Data from AppGroup Cache
    @State private var banks: [CachedBank] = []
    @State private var transactionTypes: [CachedTransactionType] = []
    @State private var quickActions: [CachedQuickAction] = []
    
    // Form selections
    @State private var selectedAttachmentId: UUID? = nil
    @State private var selectedBankId: String = ""
    @State private var selectedTypeId: String = ""
    @State private var selectedQAs: Set<String> = []
    @State private var titleText: String = ""
    @State private var amountString: String = ""
    @State private var selectedDate: Date = Date()
    @State private var receiptUrl: String = ""
    
    // Parsing State
    @State private var parseState: ReceiptParseState = .idle
    
    // Saving and Alert state
    @State private var isSaving: Bool = false
    @State private var savingStatusText: String = "İşlem Kaydediliyor..."
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""

    private var uidInfo: (uid: String?, source: String) {
        AppGroupStorage.getUID()
    }
    
    private var firebaseUID: String? {
        Auth.auth().currentUser?.uid
    }
    
    private var resolvedUID: String? {
        if let uid = firebaseUID, !uid.isEmpty { return uid }
        return uidInfo.uid
    }

    var body: some View {
        NavigationView {
            Form {
                // 1. Paylaşılan Belgeler ve Radio Button Seçimi
                if !attachments.isEmpty {
                    Section(
                        header: Text("Paylaşılan Belgeler (\(attachments.count))"),
                        footer: attachments.count > 1 ? Text("Birden fazla belge tespit edildi. Sadece seçili olan (◉) belge Drive'a yüklenecektir.") : nil
                    ) {
                        ForEach(attachments) { att in
                            let info = fileDisplayInfo(for: att)
                            
                            Button(action: {
                                selectedAttachmentId = att.id
                                parseSelectedDocument()
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedAttachmentId == att.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(selectedAttachmentId == att.id ? .blue : .gray)
                                        .font(.title3)
                                    
                                    Image(systemName: info.icon)
                                        .foregroundColor(info.color)
                                        .font(.title2)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(att.fileName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text("\(att.fileData.count / 1024) KB • \(info.label)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if selectedAttachmentId == att.id {
                                        Text("Seçildi")
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.12))
                                            .foregroundColor(.blue)
                                            .cornerRadius(6)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        // Ayrıştırma Durumu Bilgi Çubuğu (Yeşil Onay veya Ayrıştırma Yapılamadı Uyarısı)
                        switch parseState {
                        case .success(let bankName, let amount):
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.subheadline)
                                Text("Otomatik Ayrıştırıldı: **\(bankName)** • **\(amount) ₺**")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            
                        case .failed:
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                                Text("Dekont otomatik ayrıştırılamadı. Banka ve tutarı manuel girebilirsiniz.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            
                        case .parsing:
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Dekont taranıyor...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            
                        case .idle:
                            EmptyView()
                        }
                    }
                }
                
                // 2. İşlem Bilgileri
                Section(header: Text("İşlem Bilgileri")) {
                    TextField("Açıklama / Başlık", text: $titleText)
                    
                    if banks.isEmpty {
                        HStack {
                            Text("Banka")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Banka verisi yok — Nova uygulamasını açın")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Picker("Banka", selection: $selectedBankId) {
                            Text("Banka Seçin").tag("")
                            ForEach(banks) { b in
                                Text(b.name).tag(b.id)
                            }
                        }
                    }
                    
                    DatePicker("Tarih", selection: $selectedDate, displayedComponents: .date)
                    
                    HStack {
                        Text("Tutar (₺)")
                        Spacer()
                        TextField("0,00 (Örn: -9845,60)", text: $amountString)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    if transactionTypes.isEmpty {
                        HStack {
                            Text("İşlem Türü")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Tür verisi yok")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Picker("İşlem Türü", selection: $selectedTypeId) {
                            Text("Tür Seçin").tag("")
                            ForEach(transactionTypes) { t in
                                Text(t.name).tag(t.id)
                            }
                        }
                    }
                }
                
                // 3. Hızlı İşlemler (Banka Sayfasındaki Gibi Alt Alta Liste)
                if !quickActions.isEmpty {
                    Section(header: Text("Hızlı İşlemler")) {
                        ForEach(quickActions) { qa in
                            Button(action: {
                                if selectedQAs.contains(qa.id) {
                                    selectedQAs.remove(qa.id)
                                } else {
                                    selectedQAs.insert(qa.id)
                                }
                            }) {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(Color(hex: tagColorToHex(qa.color)))
                                        .frame(width: 10, height: 10)
                                    
                                    Text(qa.name)
                                        .foregroundColor(.primary)
                                        .font(.body)
                                    
                                    Spacer()
                                    
                                    if selectedQAs.contains(qa.id) {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.bold))
                                            .foregroundColor(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                
                // 4. Dekont Bağlantısı
                Section(header: Text("Dekont Bağlantısı (URL)")) {
                    TextField("Dekont URL (Opsiyonel)", text: $receiptUrl)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
            }
            .navigationTitle("Nova - İşlem Ekle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Vazgeç") { onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(savingStatusText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button("Kaydet") {
                            executeSaveFlow()
                        }
                        .disabled(selectedBankId.isEmpty)
                    }
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("Tamam", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .onAppear {
                loadDataFromCache()
                if selectedAttachmentId == nil, let first = attachments.first {
                    selectedAttachmentId = first.id
                }
                parseSelectedDocument()
            }
        }
    }

    // MARK: - Parse Selected Document
    private func parseSelectedDocument() {
        guard let selectedId = selectedAttachmentId,
              let att = attachments.first(where: { $0.id == selectedId }) else {
            parseState = .idle
            return
        }
        
        parseState = .parsing
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SmartReceiptParser.parse(data: att.fileData, mimeType: att.mimeType, banks: self.banks)
            
            DispatchQueue.main.async {
                if let amount = result.amount, !amount.isEmpty {
                    self.amountString = amount
                }
                
                if let bankId = result.bankId, !bankId.isEmpty {
                    self.selectedBankId = bankId
                } else if let detectedName = result.bankName {
                    // Fallback matching against banks
                    let normDetected = normalizeTurkishSearch(detectedName)
                    if let matched = self.banks.first(where: {
                        let bNorm = normalizeTurkishSearch($0.name)
                        return bNorm.contains(normDetected) || normDetected.contains(bNorm) ||
                               (normDetected.contains("is") && bNorm.contains("is")) ||
                               (normDetected.contains("vakif") && bNorm.contains("vakif")) ||
                               (normDetected.contains("akbank") && bNorm.contains("akbank"))
                    }) {
                        self.selectedBankId = matched.id
                    }
                }
                
                if let bankName = result.bankName, let amount = result.amount {
                    self.parseState = .success(bankName: bankName, amount: amount)
                } else if let bankName = result.bankName {
                    self.parseState = .success(bankName: bankName, amount: self.amountString.isEmpty ? "—" : self.amountString)
                } else if let amount = result.amount {
                    self.parseState = .success(bankName: "Tespit Edildi", amount: amount)
                } else {
                    self.parseState = .failed
                }
            }
        }
    }

    // MARK: - Helper to display icon and label based on file type
    private func fileDisplayInfo(for att: SharedAttachment) -> (icon: String, color: Color, label: String) {
        let lowerName = att.fileName.lowercased()
        let lowerMime = att.mimeType.lowercased()
        
        if lowerMime.contains("pdf") || lowerName.hasSuffix(".pdf") {
            return ("doc.richtext.fill", .red, "PDF Belgesi")
        } else if lowerMime.contains("word") || lowerMime.contains("document") || lowerName.hasSuffix(".docx") || lowerName.hasSuffix(".doc") {
            return ("doc.text.fill", .blue, "Word Belgesi")
        } else if lowerMime.contains("image") || lowerName.hasSuffix(".jpg") || lowerName.hasSuffix(".jpeg") || lowerName.hasSuffix(".png") {
            return ("photo.fill", .green, "Görsel")
        } else if lowerMime.contains("sheet") || lowerMime.contains("excel") || lowerName.hasSuffix(".xlsx") || lowerName.hasSuffix(".xls") {
            return ("tablecells.fill", .green, "Excel Tablosu")
        } else {
            return ("doc.fill", .gray, "Belge")
        }
    }

    // MARK: - Load from AppGroup Disk Cache
    private func loadDataFromCache() {
        let cachedBanks = AppGroupStorage.getBanks()
        if !cachedBanks.isEmpty {
            let sortedBanks = cachedBanks.sorted { $0.order < $1.order }
            banks = sortedBanks
            if selectedBankId.isEmpty, let first = sortedBanks.first {
                selectedBankId = first.id
            }
        }
        
        let cachedTypes = AppGroupStorage.getTransactionTypes()
        if !cachedTypes.isEmpty {
            let sortedTypes = cachedTypes.sorted { $0.order < $1.order }
            transactionTypes = sortedTypes
            if selectedTypeId.isEmpty, let first = sortedTypes.first {
                selectedTypeId = first.id
            }
        }
        
        let cachedQAs = AppGroupStorage.getQuickActions()
        if !cachedQAs.isEmpty {
            let sortedQAs = cachedQAs.sorted { $0.order < $1.order }
            quickActions = sortedQAs
        }
    }
    
    // MARK: - Save Flow (Upload to Drive first, then Save Transaction)
    private func executeSaveFlow() {
        guard let uid = resolvedUID, !uid.isEmpty else {
            displayAlert(title: "Oturum Hatası", message: "Kullanıcı oturumu bulunamadı. Lütfen Nova ana uygulamasını açıp tekrar deneyin.")
            return
        }
        guard !selectedBankId.isEmpty else {
            displayAlert(title: "Eksik Bilgi", message: "Lütfen bir banka seçin.")
            return
        }
        
        isSaving = true
        
        Task {
            var finalReceiptUrl = self.receiptUrl
            
            // 1. Eğer bir belge seçildiyse önce Google Drive'a yükle
            if let selectedId = self.selectedAttachmentId,
               let att = self.attachments.first(where: { $0.id == selectedId }) {
                
                await MainActor.run {
                    self.savingStatusText = "Drive'a Yükleniyor..."
                }
                
                do {
                    let uploaded = try await GoogleDriveService.shared.uploadFile(
                        fileData: att.fileData,
                        fileName: att.fileName,
                        mimeType: att.mimeType
                    )
                    finalReceiptUrl = uploaded.shareUrl
                } catch {
                    await MainActor.run {
                        self.isSaving = false
                        self.displayAlert(title: "Google Drive Hatası", message: "Belge Google Drive'a yüklenemedi:\n\(error.localizedDescription)")
                    }
                    return
                }
            }
            
            // 2. Firestore'a Banka İşlemini Kaydet
            await MainActor.run {
                self.savingStatusText = "İşlem Kaydediliyor..."
            }
            
            var cleanStr = self.amountString
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "₺", with: "")
                .replacingOccurrences(of: "TL", with: "")
                .replacingOccurrences(of: "TRY", with: "")
            
            let isNegative = cleanStr.hasPrefix("-")
            if isNegative {
                cleanStr = String(cleanStr.dropFirst())
            }
            
            cleanStr = cleanStr.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            var amount = Double(cleanStr) ?? 0.0
            if isNegative {
                amount = -amount
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: self.selectedDate)
            
            var data: [String: Any] = [
                "bankId": self.selectedBankId,
                "title": self.titleText.trimmingCharacters(in: .whitespacesAndNewlines),
                "type": self.selectedTypeId,
                "quickActions": Array(self.selectedQAs),
                "amount": amount,
                "date": dateStr,
                "createdAt": FieldValue.serverTimestamp(),
                "deleted": false
            ]
            if !finalReceiptUrl.isEmpty {
                data["receiptUrl"] = finalReceiptUrl
            }
            
            Firestore.firestore()
                .collection("users").document(uid)
                .collection("bankTransactions")
                .addDocument(data: data) { error in
                    DispatchQueue.main.async {
                        self.isSaving = false
                        if let error = error {
                            self.displayAlert(title: "Kayıt Hatası", message: "İşlem kaydedilemedi:\n\(error.localizedDescription)")
                        } else {
                            self.onDone()
                        }
                    }
                }
        }
    }
    
    private func displayAlert(title: String, message: String) {
        self.alertTitle = title
        self.alertMessage = message
        self.showAlert = true
    }
}

// MARK: - Color Hex Helpers for Quick Actions
func tagColorToHex(_ colorName: String) -> String {
    switch colorName.lowercased() {
    case "red": return "#FF3B30"
    case "orange": return "#FF9500"
    case "yellow": return "#FFCC00"
    case "green": return "#34C759"
    case "mint": return "#00C7BE"
    case "teal": return "#30B0C7"
    case "cyan": return "#32ADE6"
    case "blue": return "#007AFF"
    case "indigo": return "#5856D6"
    case "purple": return "#AF52DE"
    case "pink": return "#FF2D55"
    case "brown": return "#A2845E"
    default: return "#8E8E93"
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 128, 128, 128)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
