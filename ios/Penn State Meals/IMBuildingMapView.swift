import SwiftUI

// MARK: - Models
enum IMFacilityRegion: Hashable, Sendable, Identifiable {
    var id: Self { self }
    
    case gym1(court: Int)
    case gym2
    case gym3(court: Int)
    case gym4(court: Int)
    case racquetball(court: Int)
    case turfEast
    case turfWest
    
    static func regions(for locationString: String) -> [IMFacilityRegion] {
        let lower = locationString.lowercased()
        var regions = [IMFacilityRegion]()
        
        if lower.contains("gym 1") {
            if lower.contains("court 1") { regions.append(.gym1(court: 1)) }
            if lower.contains("court 2") { regions.append(.gym1(court: 2)) }
            if lower.contains("court 3") { regions.append(.gym1(court: 3)) }
            if lower.contains("courts 2-3") { regions.append(contentsOf: [.gym1(court: 2), .gym1(court: 3)]) }
            if regions.isEmpty { regions.append(contentsOf: [.gym1(court: 1), .gym1(court: 2), .gym1(court: 3)]) }
        } else if lower.contains("gym 2") || lower.contains("mac court") {
            regions.append(.gym2)
        } else if lower.contains("gym 3") {
            if lower.contains("court 1") { regions.append(.gym3(court: 1)) }
            if lower.contains("court 2") { regions.append(.gym3(court: 2)) }
            if lower.contains("court 3") { regions.append(.gym3(court: 3)) }
            if lower.contains("courts 2-3") { regions.append(contentsOf: [.gym3(court: 2), .gym3(court: 3)]) }
            if regions.isEmpty { regions.append(contentsOf: [.gym3(court: 1), .gym3(court: 2), .gym3(court: 3)]) }
        } else if lower.contains("gym 4") {
            if lower.contains("court 1") { regions.append(.gym4(court: 1)) }
            if lower.contains("court 2") { regions.append(.gym4(court: 2)) }
            if lower.contains("court 3") { regions.append(.gym4(court: 3)) }
            if lower.contains("courts 2-3") { regions.append(contentsOf: [.gym4(court: 2), .gym4(court: 3)]) }
            if regions.isEmpty { regions.append(contentsOf: [.gym4(court: 1), .gym4(court: 2), .gym4(court: 3)]) }
        } else if lower.contains("racquetball") {
            if lower.contains("court 1") && !lower.contains("gym") { regions.append(.racquetball(court: 1)) }
            if lower.contains("2") && !lower.contains("gym") { regions.append(.racquetball(court: 2)) }
            if lower.contains("3") && !lower.contains("gym") { regions.append(.racquetball(court: 3)) }
            if lower.contains("4") && !lower.contains("gym") { regions.append(.racquetball(court: 4)) }
            if lower.contains("5") && !lower.contains("gym") { regions.append(.racquetball(court: 5)) }
            if lower.contains("6") && !lower.contains("gym") { regions.append(.racquetball(court: 6)) }
            if lower.contains("7") && !lower.contains("gym") { regions.append(.racquetball(court: 7)) }
            if regions.isEmpty {
                regions.append(contentsOf: (1...7).map { .racquetball(court: $0) })
            }
        } else if lower.contains("east") {
            regions.append(.turfEast)
        } else if lower.contains("west") {
            regions.append(.turfWest)
        } else if lower.contains("courts 7") {
            regions.append(contentsOf: (1...7).map { .racquetball(court: $0) })
        }
        
        return Array(Set(regions))
    }
}

struct IMBuildingMapView<PopoverContent: View>: View {
    let activeRegions: Set<IMFacilityRegion>
    @Binding var selectedRegion: IMFacilityRegion?
    @ViewBuilder let popoverContent: (IMFacilityRegion) -> PopoverContent
    
    // Exact colors mapped from the provided image
    private let cGym = Color(red: 0.98, green: 0.95, blue: 0.82)
    private let cRacq = Color(red: 0.45, green: 0.77, blue: 0.98)
    private let cTurf = Color(red: 0.53, green: 0.94, blue: 0.53)
    private let cGreenDark = Color(red: 0.45, green: 0.88, blue: 0.45)
    private let cStudio = Color(red: 1.0, green: 0.65, blue: 0.25)
    private let cFitness = Color(red: 0.0, green: 0.95, blue: 0.95)
    private let cSquash = Color(red: 0.98, green: 0.6, blue: 0.66)
    private let cEquip = Color(red: 0.98, green: 0.1, blue: 0.65)
    private let cGrey = Color(red: 0.85, green: 0.86, blue: 0.87)
    private let cYellow = Color(red: 0.98, green: 0.95, blue: 0.2)
    private let cRed = Color(red: 0.95, green: 0.1, blue: 0.1)
    
    private let mapAspectRatio: CGFloat = 1.3
    
    var body: some View {
        GeometryReader { proxy in
            let pad: CGFloat = 10
            let aw = proxy.size.width - pad * 2   // available width
            let ah = proxy.size.height - pad * 2   // available height
            
            let topSp: CGFloat = 4   // top row spacing
            let midSp: CGFloat = 3   // mid row spacing
            let botSp: CGFloat = 2   // bottom row spacing
            let rowSp: CGFloat = 4   // vertical row spacing
            
            // Height budget: top 28%, mid 48%, bottom 16%, rows + spacing ~8%
            let topH = ah * 0.30
            let midH = ah * 0.46
            let botH = ah * 0.16
            
            VStack(spacing: rowSp) {
                // ═══ TOP ROW ═══
                // Budget: storage 8% | gym4 38% | turf area 50% | spacing ~4%
                HStack(alignment: .bottom, spacing: topSp) {
                    // Storage
                    VStack(spacing: 3) {
                        box("114A\nStorage", cGrey)
                        box("114B\nStorage", cGrey)
                    }
                    .frame(width: aw * 0.08, height: topH * 0.65)
                    
                    // GYM 4
                    facilityContainer("GYM 4 (114)", color: cGym) {
                        HStack(spacing: 3) {
                            court(.gym4(court: 1), label: "Ct 1")
                            court(.gym4(court: 2), label: "Ct 2")
                            court(.gym4(court: 3), label: "Ct 3")
                        }
                    }
                    .frame(width: aw * 0.38, height: topH)
                    
                    // Turf + Bouldering/Climbing
                    VStack(spacing: 3) {
                        facilityContainer("Indoor Turf Field (140)", color: cTurf) {
                            HStack(spacing: 8) {
                                court(.turfWest, label: "West")
                                court(.turfEast, label: "East")
                            }
                        }
                        .frame(height: topH * 0.78)
                        
                        HStack(spacing: 3) {
                            box("Bouldering", cGreenDark)
                            box("139\nClimbing", cGreenDark)
                                .frame(width: aw * 0.10)
                        }
                    }
                    .frame(width: aw * 0.50)
                }
                .frame(height: topH)
                
                // ═══ MIDDLE ROW ═══
                // Budget: gym1 18% | rqL 8% | gym2 20% | rqR 8% | gym3 14% | right 15% | spacing ~17%
                // Total items: 7 gaps × 3px = 21px deducted implicitly via flex
                HStack(alignment: .top, spacing: midSp) {
                    // GYM 1
                    facilityContainer("GYM 1 (122)", color: cGym) {
                        VStack(spacing: 3) {
                            court(.gym1(court: 3), label: "Ct 3")
                            court(.gym1(court: 2), label: "Ct 2")
                            court(.gym1(court: 1), label: "Ct 1")
                        }
                    }
                    .frame(width: aw * 0.18)
                    
                    // Racquetball Left + Equip
                    VStack(spacing: 3) {
                        facilityContainer("Racquetball\nCourts", color: cRacq, verticalTitle: true) {
                            VStack(spacing: 1) {
                                ForEach((6...10).reversed(), id: \.self) { c in
                                    court(.racquetball(court: c), label: "\(c)")
                                }
                            }
                        }
                        box("129\nEquip RM", cEquip)
                            .frame(height: midH * 0.16)
                    }
                    .frame(width: aw * 0.08)
                    
                    // 115A + GYM 2
                    VStack(spacing: 3) {
                        box("115A Storage", cGrey)
                            .frame(height: midH * 0.07)
                        facilityContainer("GYM 2\nMAC Court (115)", color: cGym) {
                            court(.gym2, label: "MAC")
                        }
                    }
                    .frame(width: aw * 0.20)
                    
                    // Racquetball Right
                    facilityContainer("Racquetball\nCourts", color: cRacq, verticalTitle: true) {
                        VStack(spacing: 1) {
                            ForEach((1...5).reversed(), id: \.self) { c in
                                court(.racquetball(court: c), label: "\(c)")
                            }
                        }
                    }
                    .frame(width: aw * 0.08)
                    
                    // GYM 3
                    facilityContainer("GYM 3 (105)", color: cGym) {
                        VStack(spacing: 3) {
                            court(.gym3(court: 3), label: "Ct 3")
                            court(.gym3(court: 2), label: "Ct 2")
                            court(.gym3(court: 1), label: "Ct 1")
                        }
                    }
                    .frame(width: aw * 0.14)
                    
                    // Right bloc: offices, squash, wellness, restrooms
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            box("130\nClub\nSports", cGrey)
                            box("138\nWellness\nStudio", cStudio)
                        }
                        .frame(height: midH * 0.42)
                        
                        HStack(spacing: 3) {
                            box("Squash", cSquash, verticalTitle: true)
                            VStack(spacing: 3) {
                                box("REST\nROOMS", cGrey)
                                box("135\nNittany\nRoom", cGrey)
                            }
                        }
                        .frame(height: midH * 0.42)
                        
                        Spacer(minLength: 0)
                    }
                    .frame(width: aw * 0.16)
                }
                .frame(height: midH)
                
                // ═══ BOTTOM ROW ═══
                HStack(spacing: botSp) {
                    box("124/125\nFitness\nStudios", cStudio)
                        .frame(width: aw * 0.18)
                    
                    VStack(spacing: botSp) {
                        box("127", cGrey)
                        HStack(spacing: botSp) {
                            box("W", cYellow)
                            box("M", cYellow)
                        }
                    }
                    .frame(width: aw * 0.08)
                    
                    VStack(spacing: botSp) {
                        box("ELEVATOR", cGrey)
                            .frame(height: botH * 0.35)
                        box("101\nCampus Rec\nAdmin", cGrey)
                    }
                    .frame(width: aw * 0.22)
                    
                    VStack(spacing: botSp) {
                        box("Front\nDesk", cGrey)
                            .frame(height: botH * 0.35)
                        box("LOBBY", .white)
                    }
                    .frame(width: aw * 0.10)
                    
                    box("↑\nENTRY\n& EXIT", cRed)
                        .frame(width: aw * 0.06)
                    
                    box("103\nFitness\nCenter", cFitness)
                        .frame(width: aw * 0.30)
                }
                .frame(height: botH)
            }
            .padding(pad)
        }
        .aspectRatio(mapAspectRatio, contentMode: .fit)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.12), radius: 15, x: 0, y: 8)
    }
    
    // MARK: - View Builders
    
    @ViewBuilder
    private func facilityContainer(
        _ name: String,
        color: Color,
        verticalTitle: Bool = false,
        textColor: Color = .black,
        @ViewBuilder content: () -> some View
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
            
            if verticalTitle {
                HStack(spacing: 0) {
                    Text(name)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(textColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.3)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 14)
                    content().padding(2)
                }
            } else {
                VStack(spacing: 0) {
                    Text(name)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(textColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.3)
                        .padding(.top, 2)
                        .padding(.horizontal, 2)
                    content().padding(3)
                }
            }
            
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.black.opacity(0.4), lineWidth: 0.5)
        }
    }
    
    @ViewBuilder
    private func court(_ region: IMFacilityRegion, label: String = "") -> some View {
        let isActive = activeRegions.contains(region)
        
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.black.opacity(0.2), lineWidth: 0.5)
            
            if !label.isEmpty {
                 Text(label)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(Color.black.opacity(0.4))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.3)
                    .padding(1)
            }
            
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.blue, lineWidth: 3)
                    .background(Color.blue.opacity(0.15))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isActive {
                selectedRegion = (selectedRegion == region) ? nil : region
            }
        }
        .popover(isPresented: Binding(
            get: { selectedRegion == region },
            set: { if !$0 && selectedRegion == region { selectedRegion = nil } }
        )) {
            if isActive {
                popoverContent(region)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
    
    @ViewBuilder
    private func box(_ name: String, _ color: Color, verticalTitle: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                
            Text(name)
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(color == cRed ? .white : .black)
                .multilineTextAlignment(.center)
                .lineLimit(verticalTitle ? 1 : 4)
                .minimumScaleFactor(0.3)
                .rotationEffect(verticalTitle ? .degrees(-90) : .zero)
                .padding(1)
                
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.black.opacity(0.4), lineWidth: 0.5)
        }
    }
}
