import SwiftUI

struct NativeCalendarMonthView: View {
    let month: NativeCalendarMonth
    let selectedDay: Date
    let today: Date
    let counts: [Date: Int]
    let select: (Date) -> Void
    let move: (Int) -> Void
    let showToday: () -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("이전 달")
                Spacer(minLength: 0)
                Text(NativeCalendarDates.label(month.start, format: "yyyy년 M월")).font(.headline)
                Spacer(minLength: 0)
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("다음 달")
                Button("오늘", action: showToday).font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { index, text in
                    Text(text).font(.caption.weight(.semibold)).foregroundStyle(index == 0 ? Color.red : NativePalette.muted)
                        .frame(maxWidth: .infinity)
                }
                ForEach(month.days, id: \.self) { day in
                    let selected = day == NativeCalendarDates.day(selectedDay)
                    let isToday = day == NativeCalendarDates.day(today)
                    let count = counts[day] ?? 0
                    Button { select(day) } label: {
                        VStack(spacing: 3) {
                            Text("\(NativeCalendarDates.calendar.component(.day, from: day))")
                                .font(.subheadline.weight(isToday || selected ? .bold : .regular))
                            Circle().fill(selected ? Color.white : NativePalette.forest).frame(width: 5, height: 5).opacity(count > 0 ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected ? Color.white : month.contains(day) ? NativePalette.ink : NativePalette.muted)
                        .background(selected ? NativePalette.forest : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(isToday ? NativePalette.forest : Color.clear, lineWidth: 1) }
                    }.buttonStyle(.plain)
                        .accessibilityLabel(NativeCalendarDates.label(day, format: "yyyy년 M월 d일 EEEE") + (isToday ? ", 오늘" : "") + ", 일정 \(count)개")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text("한국 시간 기준 · 점이 있는 날짜에는 일정이 있습니다.").font(.caption).foregroundStyle(NativePalette.muted)
        }.padding(.vertical, 8)
    }
}
