import Foundation

struct NativeFieldSurvey: Codable {
    var revision = 0
    var attendance_start: String?
    var attendance_end: String?
    var departure = ""
    var driver_seats = 0
}
struct NativeFieldResource: Codable, Identifiable {
    var id: String
    var name: String
    var capacity: Int
}
struct NativeFieldVehicle: Codable, Identifiable {
    var id: String
    var label: String
    var seat_count: Int
    var driver_user_id: String?
}
struct NativeFieldAssignment: Codable, Identifiable {
    var user_id: String
    var group_id: String?
    var vehicle_id: String?
    var room_id: String?
    var id: String { user_id }
}
struct NativeFieldParticipant: Decodable, Identifiable {
    let user_id: String
    let display_name: String
    let response: String
    let church_id: String?
    let church_name: String?
    let survey: NativeFieldSurvey?
    let group_id: String?
    let vehicle_id: String?
    let room_id: String?
    let checked_at: String?
    var id: String { user_id }
}
struct NativeFieldStaff: Decodable, Identifiable {
    let user_id: String
    let capabilities: [String]
    let expires_at: String
    var id: String { user_id }
}
struct NativeFieldState: Decodable {
    struct Plan: Decodable { let revision: Int; let vehicles: [NativeFieldVehicle] }
    let capabilities: [String]
    let can_grant: Bool
    let survey: NativeFieldSurvey?
    let plan: Plan
    let groups: [NativeFieldResource]
    let rooms: [NativeFieldResource]
    let participants: [NativeFieldParticipant]
    let staff: [NativeFieldStaff]
    var starts_at: String? = nil
    var ends_at: String? = nil
    var is_closed: Bool? = nil
    static func parse(_ value: Any) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
struct NativeFieldDraft {
    var revision: Int
    var groups: [NativeFieldResource]
    var rooms: [NativeFieldResource]
    var vehicles: [NativeFieldVehicle]
    var assignments: [NativeFieldAssignment]
    init(_ state: NativeFieldState) {
        revision = state.plan.revision; groups = state.groups; rooms = state.rooms; vehicles = state.plan.vehicles
        assignments = state.participants.filter { $0.response == "yes" }.map { NativeFieldAssignment(user_id: $0.user_id, group_id: $0.group_id, vehicle_id: $0.vehicle_id, room_id: $0.room_id) }
    }
    var capacityError: String? {
        for (items, key) in [(groups, \NativeFieldAssignment.group_id), (rooms, \NativeFieldAssignment.room_id), (vehicles.map { NativeFieldResource(id: $0.id, name: $0.label, capacity: $0.seat_count) }, \NativeFieldAssignment.vehicle_id)] {
            for item in items {
                if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.capacity < 1 || item.capacity > 1000 { return "이름과 정원을 확인하세요." }
                if assignments.filter({ $0[keyPath: key] == item.id }).count > item.capacity { return "\(item.name): 정원 초과" }
            }
        }
        if vehicles.contains(where: { $0.seat_count > 100 }) { return "차량은 최대 100석입니다." }
        return nil
    }
    mutating func automatic(_ kind: String, participants: [NativeFieldParticipant]) {
        if kind == "church" {
            let byChurch = Dictionary(grouping: participants.filter { $0.response == "yes" && $0.church_id != nil }, by: { $0.church_id! })
            guard byChurch.count <= 50 else { return }
            let keys = byChurch.keys.sorted()
            groups = keys.map { NativeFieldResource(id: UUID().uuidString, name: byChurch[$0]?.first?.church_name ?? "교회", capacity: byChurch[$0]!.count) }
            for index in assignments.indices {
                let church = participants.first { $0.user_id == assignments[index].user_id }?.church_id
                assignments[index].group_id = church.flatMap { keys.firstIndex(of: $0) }.map { groups[$0].id }
            }
            return
        }
        let key: WritableKeyPath<NativeFieldAssignment, String?> = kind == "vehicle" ? \.vehicle_id : kind == "room" ? \.room_id : \.group_id
        let resources = kind == "vehicle" ? vehicles.map { NativeFieldResource(id: $0.id, name: $0.label, capacity: $0.seat_count) } : kind == "room" ? rooms : groups
        var used: [String: Int] = [:], cursor = 0
        if kind == "vehicle" { for vehicle in vehicles where vehicle.driver_user_id != nil { used[vehicle.id] = 1 } }
        for index in assignments.indices {
            if kind == "vehicle", let own = vehicles.first(where: { $0.driver_user_id == assignments[index].user_id }) { assignments[index].vehicle_id = own.id; continue }
            assignments[index][keyPath: key] = nil
            for offset in resources.indices {
                let target = (cursor + offset) % resources.count, resource = resources[target]
                if used[resource.id, default: 0] < resource.capacity {
                    assignments[index][keyPath: key] = resource.id; used[resource.id, default: 0] += 1; cursor = (target + 1) % resources.count; break
                }
            }
        }
    }
    func payload(occurrenceID: String) throws -> [String: Any] {
        func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        return ["p_occurrence_id": occurrenceID, "p_revision": revision, "p_groups": try json(groups), "p_rooms": try json(rooms), "p_vehicles": try json(vehicles), "p_assignments": try json(assignments)]
    }
}
