import SwiftUI
import SwiftData
import PhotosUI
import Photos
import MapKit
import CoreLocation
import Vision

// MARK: - Data models

@Model
class Shop {
    var name: String

    init(name: String) {
        self.name = name
    }
}

// A drink on a shop's menu. Only shown in the Drink dropdown when that shop is selected.
@Model
class ShopDrink {
    var shopName: String
    var drinkName: String

    init(shopName: String, drinkName: String) {
        self.shopName = shopName
        self.drinkName = drinkName
    }
}

// One saved spot for a shop. A shop can have many of these (one per branch).
@Model
class ShopLocation {
    var shopName: String
    var latitude: Double
    var longitude: Double
    var address: String = ""

    init(shopName: String, latitude: Double, longitude: Double, address: String = "") {
        self.shopName = shopName
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }
}

@Model
class Drink {
    var date: Date
    var shop: String
    var name: String
    var sweetness: String   // e.g. "50%" or "Less"
    var ice: String         // e.g. "30%" or "Regular"
    var rating: Int
    var notes: String
    var address: String = ""   // which branch (street address)
    @Attribute(.externalStorage) var photoData: Data?

    init(date: Date = .now, shop: String = "", name: String = "",
         sweetness: String = "", ice: String = "", rating: Int = 0,
         notes: String = "", photoData: Data? = nil) {
        self.date = date
        self.shop = shop
        self.name = name
        self.sweetness = sweetness
        self.ice = ice
        self.rating = rating
        self.notes = notes
        self.photoData = photoData
    }
}

// MARK: - App entry

@main
struct BobaApp: App {
    var body: some Scene {
        WindowGroup {
            DrinkListView()
        }
        .modelContainer(for: [Drink.self, Shop.self, ShopLocation.self, ShopDrink.self])
    }
}

// MARK: - List screen

struct DrinkListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Drink.date, order: .reverse) private var drinks: [Drink]
    @Query private var shopDrinks: [ShopDrink]
    @Query private var allShops: [Shop]
    @AppStorage("didBackfillMenus") private var didBackfill = false
    @State private var showingNew = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(drinks) { drink in
                    NavigationLink {
                        DrinkEditView(drink: drink, isNew: false)
                    } label: {
                        DrinkRow(drink: drink)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(drinks[i]) }
                }
            }
            .navigationTitle("Boba Log")
            .onAppear { backfillMenus() }
            .toolbar {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showingNew) {
                NewDrinkView()
            }
        }
    }

    // Runs once: adds shops and drinks from entries you logged before the lists existed.
    // It must not run every time, or shops/drinks you delete would come back.
    private func backfillMenus() {
        guard !didBackfill, !drinks.isEmpty else { return }
        var knownShops = Set(allShops.map { $0.name })
        var knownDrinks = Set(shopDrinks.map { $0.shopName + "|" + $0.drinkName.lowercased() })
        for d in drinks where !d.shop.isEmpty {
            if !knownShops.contains(d.shop) {
                context.insert(Shop(name: d.shop))
                knownShops.insert(d.shop)
            }
            let key = d.shop + "|" + d.name.lowercased()
            if !d.name.isEmpty && !knownDrinks.contains(key) {
                context.insert(ShopDrink(shopName: d.shop, drinkName: d.name))
                knownDrinks.insert(key)
            }
        }
        didBackfill = true
    }
}

// Holds the new drink so it isn't recreated (and reset) when the list screen refreshes
struct NewDrinkView: View {
    @State private var drink = Drink()

    var body: some View {
        NavigationStack {
            DrinkEditView(drink: drink, isNew: true)
        }
    }
}

struct DrinkRow: View {
    let drink: Drink

    var body: some View {
        HStack {
            if let data = drink.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipped()
            }
            VStack(alignment: .leading) {
                Text(drink.name.isEmpty ? "Untitled drink" : drink.name)
                    .font(.headline)
                Text(drink.shop)
                if !drink.address.isEmpty {
                    Text(drink.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(drink.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
            }
        }
    }
}

// MARK: - Sweetness / ice dropdown

struct LevelPicker: View {
    let title: String
    @Binding var value: String

    private let percents = [0, 25, 50, 75, 100].map { "\($0)%" }
    private let words = ["Less", "Regular", "More"]

    var body: some View {
        Picker(title, selection: $value) {
            Text("Not set").tag("")
            Section("Level") {
                ForEach(words, id: \.self) { Text($0).tag($0) }
            }
            Section("Percent") {
                ForEach(percents, id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

// MARK: - Location suggestion

struct Suggestion: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let location: CLLocation
}

// MARK: - Text recognition (OCR)

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// One line of text read from a photo, with its size and position
struct OCRLine {
    let text: String
    let height: CGFloat   // text size, relative to the photo height
    let x: CGFloat        // left edge
    let y: CGFloat        // vertical middle (1 = top of the photo)
}

// Reads the printed text in a photo, top of the photo first
func recognizeText(in data: Data) async -> [OCRLine] {
    guard let image = UIImage(data: data), let cgImage = image.cgImage else { return [] }
    let orientation = CGImagePropertyOrientation(image.imageOrientation)
    return await Task.detached {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([request])
        let results = request.results ?? []
        let lines = results.compactMap { (obs: VNRecognizedTextObservation) -> OCRLine? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let box = obs.boundingBox
            return OCRLine(text: text, height: box.height, x: box.minX, y: box.midY)
        }
        return lines.sorted { $0.y > $1.y }
    }.value
}

// MARK: - Label parsing (only reads what's printed; anything unclear stays blank)

private func hasWord(_ text: String, _ words: [String]) -> Bool {
    words.contains { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
}

// Turns wording like "Less", "Easy", "Extra" or "50%" into one of the dropdown options
func levelFromText(_ text: String) -> String? {
    let t = text.lowercased()
    if let range = t.range(of: "\\d{1,3}\\s*%", options: .regularExpression) {
        let number = String(t[range].filter { $0.isNumber })
        return ["0", "25", "50", "75", "100"].contains(number) ? number + "%" : nil
    }
    if hasWord(t, ["no", "zero", "without"]) { return "0%" }
    if hasWord(t, ["half"]) { return "50%" }
    if hasWord(t, ["more", "extra"]) { return "More" }
    if hasWord(t, ["less", "easy", "light", "low"]) { return "Less" }
    if hasWord(t, ["regular", "normal", "standard", "full"]) { return "Regular" }
    return nil
}

// Looks for a sweetness line and an ice line in the text read from the photo
func parseLabel(_ lines: [String]) -> (sweetness: String?, ice: String?) {
    var sweetness: String?
    var ice: String?
    for line in lines {
        for part in line.split(whereSeparator: { ",/|".contains($0) }) {
            let segment = String(part).lowercased()
            if sweetness == nil, hasWord(segment, ["sweet", "sweetness", "sugar"]) {
                sweetness = levelFromText(segment)
            }
            if ice == nil, hasWord(segment, ["ice"]) {   // "iced" does not count
                ice = levelFromText(segment)
            }
        }
    }
    return (sweetness, ice)
}

// Finds the drink name printed on the label. Looks for the line that starts with a
// quantity like "1x", or else the line under the order number (#207). A name that wraps
// onto more lines is joined while the text stays the same size. Returns nil if unsure.
func parseDrinkName(_ lines: [OCRLine]) -> String? {
    let quantity = "^\\s*\\d+\\s*[xX×]"
    var start: Int?
    var firstText = ""

    // Anchor 1: a quantity like "1x"
    for (i, line) in lines.enumerated() {
        guard line.text.range(of: quantity + "(\\s|$)", options: .regularExpression) != nil else { continue }
        let rest = line.text.replacingOccurrences(of: quantity + "\\s*", with: "", options: .regularExpression)
        if !rest.isEmpty {
            start = i
            firstText = rest
        } else {
            // "1x" was read as its own line: the name is the line on the same row, to its right
            let others = lines.indices.filter { $0 != i }
            if let j = others.min(by: { abs(lines[$0].y - line.y) < abs(lines[$1].y - line.y) }),
               abs(lines[j].y - line.y) < line.height, lines[j].x > line.x {
                start = j
                firstText = lines[j].text
            }
        }
        break
    }

    // Anchor 2: the first line below an order number like "#207"
    if start == nil,
       let a = lines.firstIndex(where: { $0.text.range(of: "#\\s*\\d+", options: .regularExpression) != nil }) {
        let anchor = lines[a]
        if let j = lines.indices.first(where: { $0 > a && abs(lines[$0].y - anchor.y) > anchor.height }) {
            start = j
            firstText = lines[j].text
        }
    }

    guard let start else { return nil }

    // Join following lines of the same text size, stopping at option lines (sweetness, ice, milk...)
    var parts = [firstText]
    let nameHeight = lines[start].height
    var next = start + 1
    while parts.count < 3, next < lines.count {
        let candidate = lines[next]
        if candidate.text.range(of: quantity + "\\s*$", options: .regularExpression) != nil {
            next += 1   // a lone "1x" sitting between lines
            continue
        }
        let isOption = hasWord(candidate.text.lowercased(),
                               ["sweet", "sweetness", "sugar", "ice", "milk", "no", "oz", "add", "extra", "with", "without", "less", "more", "easy"])
        if candidate.height >= nameHeight * 0.85 && !isOption {
            parts.append(candidate.text)
            next += 1
        } else {
            break
        }
    }
    return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
}

// What we look for in Apple Maps. Edit this list to add or remove kinds of shops.
let searchTerms = ["bubble tea", "boba", "tea", "matcha", "cafe", "coffee"]

// Runs every search term at once and combines the results
func searchNearby(near loc: CLLocation, radius: Double) async -> [MKMapItem] {
    await withTaskGroup(of: [MKMapItem].self) { group in
        for term in searchTerms {
            group.addTask {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = term
                request.region = MKCoordinateRegion(center: loc.coordinate,
                                                    latitudinalMeters: radius * 2,
                                                    longitudinalMeters: radius * 2)
                request.resultTypes = .pointOfInterest
                let response = try? await MKLocalSearch(request: request).start()
                return response?.mapItems ?? []
            }
        }
        var all: [MKMapItem] = []
        for await items in group { all += items }
        return all
    }
}

// Street address text for a map result, e.g. "123 Main St, Santa Clara"
func addressText(_ item: MKMapItem) -> String {
    let p = item.placemark
    let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
    let parts: [String?] = [street.isEmpty ? nil : street, p.locality]
    return parts.compactMap { $0 }.joined(separator: ", ")
}

// MARK: - Camera

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// Asks the phone for its current location once (used for photos taken in the app,
// which don't carry location data the way Camera app photos do)
class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func current() async -> CLLocation? {
        await withCheckedContinuation { cont in
            continuation = cont
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                finish(nil)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }
}

// MARK: - Add / edit screen

struct DrinkEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Shop.name) private var shops: [Shop]
    @Query private var locations: [ShopLocation]
    @Query(sort: \ShopDrink.drinkName) private var shopDrinks: [ShopDrink]
    @Bindable var drink: Drink
    let isNew: Bool

    @State private var pickerItem: PhotosPickerItem?
    @State private var showingAddShop = false
    @State private var newShopName = ""
    @State private var photoLocation: CLLocation?      // used only to find suggestions
    @State private var suggestions: [Suggestion] = []
    @State private var confirmedLocation: CLLocation?  // what actually gets saved to the shop
    @State private var confirmedAddress = ""
    @State private var locationLabel: String?
    @State private var showingSearch = false
    @State private var showingAddDrink = false
    @State private var newDrinkName = ""
    @State private var didSave = false
    @State private var ocrLines: [OCRLine] = []
    @State private var autoDrinkName: String?   // drink name we filled in from the photo
    @State private var filledFromPhoto: [String] = []
    @State private var showingCamera = false
    @State private var showingManageShops = false
    @State private var showingManageDrinks = false
    @State private var locationFetcher = LocationFetcher()
    @State private var didCaptureStart = false
    @State private var startShop = ""
    @State private var startName = ""

    var body: some View {
        Form {
            Section("Photo") {
                if let data = drink.photoData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                HStack {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Label("Choose Photo", systemImage: "photo")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button {
                        showingCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                }
                if !UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Text("The camera isn't available here (it doesn't work in the simulator).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !recognizedLines.isEmpty {
                Section("Text read from photo (temporary)") {
                    if !filledFromPhoto.isEmpty {
                        Text("Filled from photo: " + filledFromPhoto.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Text("Tap a line to use it as the drink name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(recognizedLines.enumerated()), id: \.offset) { _, line in
                        Button {
                            drink.name = line
                            autoDrinkName = nil
                        } label: {
                            Text(line).foregroundStyle(.primary)
                        }
                    }
                }
            }

            if photoLocation != nil {
                Section("Near where the photo was taken") {
                    ForEach(suggestions) { suggestion in
                        Button {
                            pickSuggestion(suggestion)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(suggestion.name)
                                if !suggestion.address.isEmpty {
                                    Text(suggestion.address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button("Show more shops nearby") {
                        Task {
                            if let loc = photoLocation {
                                await updateSuggestions(for: loc, radius: 3000, limit: 15)
                            }
                        }
                    }
                }
            }

            Section("Details") {
                Button {
                    showingSearch = true
                } label: {
                    Label("Search for a shop or address", systemImage: "magnifyingglass")
                        .fontWeight(.semibold)
                }

                HStack {
                    Text("Shop")
                    Spacer()
                    Menu {
                        Picker("Shop", selection: $drink.shop) {
                            Text("None").tag("")
                            ForEach(shops) { shop in
                                Text(shop.name).tag(shop.name)
                            }
                        }
                        Divider()
                        Button("Add Shop Manually...") { showingAddShop = true }
                        Button(role: .destructive) {
                            showingManageShops = true
                        } label: {
                            Label("Delete Shops...", systemImage: "trash")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(drink.shop.isEmpty ? "None" : drink.shop)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                        }
                    }
                }

                if let label = shownLocation {
                    HStack {
                        Text("Location: \(label)")
                        Spacer()
                        Button("Clear") {
                            confirmedLocation = nil
                            confirmedAddress = ""
                            locationLabel = nil
                            drink.address = ""
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    Text("Drink")
                    Spacer()
                    Menu {
                        Picker("Drink", selection: $drink.name) {
                            Text("None").tag("")
                            ForEach(drinksForShop) { item in
                                Text(item.drinkName).tag(item.drinkName)
                            }
                        }
                        Divider()
                        Button("Add Drink Manually...") { showingAddDrink = true }
                        if !drinksForShop.isEmpty {
                            Button(role: .destructive) {
                                showingManageDrinks = true
                            } label: {
                                Label("Delete Drinks...", systemImage: "trash")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(drink.name.isEmpty ? "None" : drink.name)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                        }
                    }
                }
                LevelPicker(title: "Sweetness", value: $drink.sweetness)
                LevelPicker(title: "Ice", value: $drink.ice)
                DatePicker("Date", selection: $drink.date)
                Stepper("Rating: \(drink.rating)/5", value: $drink.rating, in: 0...5)
            }

            Section("Notes") {
                TextField("Notes", text: $drink.notes, axis: .vertical)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isNew ? "New Drink" : "Edit Drink")
        .alert("New Shop", isPresented: $showingAddShop) {
            TextField("Shop name", text: $newShopName)
            Button("Add") { addShop() }
            Button("Cancel", role: .cancel) { newShopName = "" }
        }
        .alert("New Drink", isPresented: $showingAddDrink) {
            TextField("Drink name", text: $newDrinkName)
            Button("Add") { addDrink() }
            Button("Cancel", role: .cancel) { newDrinkName = "" }
        }
        .sheet(isPresented: $showingSearch) {
            LocationSearchView(near: photoLocation, onPick: pickSearchResult)
        }
        .sheet(isPresented: $showingManageShops) {
            ManageShopsView(onDeleted: shopDeleted)
        }
        .sheet(isPresented: $showingManageDrinks) {
            ManageDrinksView(shopName: drink.shop, onDeleted: drinkDeleted)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView { image in
                if let data = image.jpegData(compressionQuality: 0.9) {
                    Task { await loadCameraPhoto(data) }
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            // Remember what the entry started with, so just viewing an old entry
            // doesn't re-add a shop's drink that you deleted
            if !didCaptureStart {
                startShop = drink.shop
                startName = drink.name
                didCaptureStart = true
            }
        }
        .onDisappear {
            if !isNew && !didSave {
                recordLocation()
                if shopOrDrinkChanged { recordShopDrink() }
            }
        }
        .onChange(of: pickerItem) {
            Task { await loadPhoto() }
        }
        .onChange(of: drink.shop) {
            matchDrink()
        }
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    didSave = true
                    recordLocation()
                    if isNew || shopOrDrinkChanged { recordShopDrink() }
                    if isNew { context.insert(drink) }
                    try? context.save()
                    dismiss()
                }
            }
            // Lets you close the keyboard (e.g. after typing notes)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
        }
    }

    private var recognizedLines: [String] { ocrLines.map { $0.text } }

    private var shopOrDrinkChanged: Bool {
        drink.shop != startShop || drink.name != startName
    }

    // Called after a shop is deleted from the manage list
    private func shopDeleted(_ name: String) {
        if drink.shop == name {
            drink.shop = ""
            drink.address = ""
            confirmedLocation = nil
            confirmedAddress = ""
            locationLabel = nil
        }
    }

    // Called after a drink is deleted from the manage list
    private func drinkDeleted(_ name: String) {
        if drink.name == name {
            drink.name = ""
            autoDrinkName = nil
        }
    }

    // Fills in the drink if the label contains one of this shop's saved drinks
    private func matchDrink() {
        guard drink.name.isEmpty || drink.name == autoDrinkName, !recognizedLines.isEmpty else { return }
        let text = recognizedLines.joined(separator: " ").lowercased()
        let best = drinksForShop
            .filter { text.contains($0.drinkName.lowercased()) }
            .max { $0.drinkName.count < $1.drinkName.count }
        if let best {
            drink.name = best.drinkName
            autoDrinkName = best.drinkName
            markFilled("Drink")
        }
    }

    private func markFilled(_ field: String) {
        if !filledFromPhoto.contains(field) { filledFromPhoto.append(field) }
    }

    // Drinks saved for the currently selected shop (none if no shop is selected)
    private var drinksForShop: [ShopDrink] {
        drink.shop.isEmpty ? [] : shopDrinks.filter { $0.shopName == drink.shop }
    }

    private func addDrink() {
        let name = newDrinkName.trimmingCharacters(in: .whitespaces)
        newDrinkName = ""
        guard !name.isEmpty else { return }

        if let existing = drinksForShop.first(where: { $0.drinkName.lowercased() == name.lowercased() }) {
            drink.name = existing.drinkName
        } else {
            if !drink.shop.isEmpty {
                context.insert(ShopDrink(shopName: drink.shop, drinkName: name))
            }
            drink.name = name
        }
    }

    // Remember this drink for this shop so it shows up in the dropdown next time
    private func recordShopDrink() {
        guard !drink.shop.isEmpty, !drink.name.isEmpty else { return }
        let exists = shopDrinks.contains {
            $0.shopName == drink.shop && $0.drinkName.lowercased() == drink.name.lowercased()
        }
        if !exists {
            context.insert(ShopDrink(shopName: drink.shop, drinkName: drink.name))
        }
    }

    // Shows the location picked this session, or the address already saved on the drink
    private var shownLocation: String? {
        if let label = locationLabel { return label }
        return drink.address.isEmpty ? nil : drink.address
    }

    private func addShop() {
        let name = newShopName.trimmingCharacters(in: .whitespaces)
        newShopName = ""
        guard !name.isEmpty else { return }
        selectShop(name)
    }

    // Select a shop by name; adds it to the dropdown list if it's new
    private func selectShop(_ name: String) {
        if let existing = shops.first(where: { $0.name.lowercased() == name.lowercased() }) {
            drink.shop = existing.name
        } else {
            context.insert(Shop(name: name))
            drink.shop = name
        }
    }

    // Save the confirmed location to the selected shop (only if you tapped a suggestion or searched)
    private func recordLocation() {
        guard let loc = confirmedLocation, !drink.shop.isEmpty else { return }
        let match = locations.first {
            $0.shopName == drink.shop &&
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: loc) < 100
        }
        if let match {
            if match.address.isEmpty { match.address = confirmedAddress }
        } else {
            context.insert(ShopLocation(shopName: drink.shop,
                                        latitude: loc.coordinate.latitude,
                                        longitude: loc.coordinate.longitude,
                                        address: confirmedAddress))
        }
        confirmedLocation = nil   // already saved; prevents a duplicate on leaving the screen
    }

    private func pickSuggestion(_ suggestion: Suggestion) {
        selectShop(suggestion.name)
        confirmedLocation = suggestion.location
        confirmedAddress = suggestion.address
        drink.address = suggestion.address
        locationLabel = suggestion.address.isEmpty ? suggestion.name : suggestion.address
    }

    private func pickSearchResult(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        let address = addressText(item)
        confirmedLocation = CLLocation(latitude: c.latitude, longitude: c.longitude)
        confirmedAddress = address
        drink.address = address
        locationLabel = address.isEmpty ? (item.name ?? "Selected location") : address
        // A business result selects/creates that shop. A plain address just sets the location,
        // and you choose or add the shop yourself.
        if item.pointOfInterestCategory != nil, let name = item.name {
            selectShop(name)
        }
    }

    private func updateSuggestions(for loc: CLLocation, radius: Double, limit: Int) async {
        var found: [Suggestion] = []

        // 1. Shops you've already saved within the radius
        for l in locations {
            let saved = CLLocation(latitude: l.latitude, longitude: l.longitude)
            if saved.distance(from: loc) < radius && !found.contains(where: { $0.name == l.shopName }) {
                found.append(Suggestion(name: l.shopName, address: l.address, location: saved))
            }
        }

        // 2. Apple Maps search for boba, tea, matcha, cafes and coffee within the radius, closest first
        do {
            let items = await searchNearby(near: loc, radius: radius)
            var mapResults: [Suggestion] = []
            for item in items {
                guard let name = item.name else { continue }
                let c = item.placemark.coordinate
                let place = CLLocation(latitude: c.latitude, longitude: c.longitude)
                if place.distance(from: loc) < radius {
                    mapResults.append(Suggestion(name: name, address: addressText(item), location: place))
                }
            }
            mapResults.sort { $0.location.distance(from: loc) < $1.location.distance(from: loc) }
            for r in mapResults {
                // skip a shop already listed from your saved locations at the same spot
                let duplicate = found.contains {
                    $0.name.lowercased() == r.name.lowercased() &&
                    $0.location.distance(from: r.location) < 100
                }
                if !duplicate { found.append(r) }
            }
        }

        suggestions = Array(found.prefix(limit))
    }

    // Photo picked from the library
    private func loadPhoto() async {
        guard let item = pickerItem else { return }

        if let data = try? await item.loadTransferable(type: Data.self) {
            await applyPhotoData(data)
        }

        // Read the date and location the photo was taken (if Camera location was on)
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        var location: CLLocation?
        if let id = item.itemIdentifier,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
            if let created = asset.creationDate { drink.date = created }
            location = asset.location
        }
        await applyLocation(location)
    }

    // Photo taken with the in-app camera: date is now, location is the phone's current location
    private func loadCameraPhoto(_ data: Data) async {
        await applyPhotoData(data)
        drink.date = .now
        let location = await locationFetcher.current()
        await applyLocation(location)
    }

    // Saves the photo and fills in what the label text says
    private func applyPhotoData(_ data: Data) async {
        drink.photoData = data
        filledFromPhoto = []
        if drink.name == autoDrinkName { drink.name = "" }   // replace a name from a previous photo
        autoDrinkName = nil
        ocrLines = await recognizeText(in: data)
        let parsed = parseLabel(recognizedLines)
        if let sweetness = parsed.sweetness {
            drink.sweetness = sweetness
            markFilled("Sweetness")
        }
        if let ice = parsed.ice {
            drink.ice = ice
            markFilled("Ice")
        }
        matchDrink()   // a saved drink for this shop wins, so names stay consistent
        if drink.name.isEmpty, let printed = parseDrinkName(ocrLines) {
            drink.name = printed
            autoDrinkName = printed
            markFilled("Drink")
        }
    }

    // Uses a location to suggest nearby shops (the location itself is never saved)
    private func applyLocation(_ location: CLLocation?) async {
        if let location {
            photoLocation = location
            await updateSuggestions(for: location, radius: 150, limit: 8)
        } else {
            photoLocation = nil
            suggestions = []
        }
    }
}

// MARK: - Manual search (name or address)

struct LocationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let near: CLLocation?
    let onPick: (MKMapItem) -> Void

    @State private var text = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { item in
                Button {
                    onPick(item)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "Unknown")
                        Text(addressText(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $text, prompt: "Shop name or address")
            .onSubmit(of: .search) {
                Task { await search() }
            }
            .navigationTitle("Find Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let near {
            request.region = MKCoordinateRegion(center: near.coordinate,
                                                latitudinalMeters: 30000,
                                                longitudinalMeters: 30000)
        }
        if let response = try? await MKLocalSearch(request: request).start() {
            results = response.mapItems
        }
    }
}

// MARK: - Delete shops / drinks

struct ManageShopsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Shop.name) private var shops: [Shop]
    @Query private var locations: [ShopLocation]
    @Query private var shopDrinks: [ShopDrink]
    let onDeleted: (String) -> Void
    @State private var pending: Shop?

    var body: some View {
        NavigationStack {
            List {
                ForEach(shops) { shop in
                    Text(shop.name)
                }
                .onDelete { offsets in
                    pending = offsets.first.map { shops[$0] }
                }
            }
            .overlay {
                if shops.isEmpty {
                    Text("No shops saved")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Delete Shops")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete this shop?",
                   isPresented: Binding(get: { pending != nil },
                                        set: { if !$0 { pending = nil } }),
                   presenting: pending) { shop in
                Button("Delete", role: .destructive) { delete(shop) }
                Button("Cancel", role: .cancel) {}
            } message: { shop in
                Text("\(shop.name) will be removed from your shop list, along with its saved locations and drink list. Drinks you've already logged are kept.")
            }
        }
    }

    private func delete(_ shop: Shop) {
        let name = shop.name
        for l in locations where l.shopName == name { context.delete(l) }
        for d in shopDrinks where d.shopName == name { context.delete(d) }
        context.delete(shop)
        try? context.save()
        onDeleted(name)
    }
}

struct ManageDrinksView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ShopDrink.drinkName) private var shopDrinks: [ShopDrink]
    let shopName: String
    let onDeleted: (String) -> Void
    @State private var pending: ShopDrink?

    private var drinks: [ShopDrink] {
        shopDrinks.filter { $0.shopName == shopName }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(drinks) { item in
                    Text(item.drinkName)
                }
                .onDelete { offsets in
                    pending = offsets.first.map { drinks[$0] }
                }
            }
            .overlay {
                if drinks.isEmpty {
                    Text("No drinks saved for this shop")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Drinks at \(shopName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete this drink?",
                   isPresented: Binding(get: { pending != nil },
                                        set: { if !$0 { pending = nil } }),
                   presenting: pending) { item in
                Button("Delete", role: .destructive) { delete(item) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("\(item.drinkName) will be removed from \(shopName)'s drink list. Entries you've already logged are kept.")
            }
        }
    }

    private func delete(_ item: ShopDrink) {
        let name = item.drinkName
        context.delete(item)
        try? context.save()
        onDeleted(name)
    }
}
