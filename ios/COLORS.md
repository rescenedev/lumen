# Lumen iOS 색상 구성 (스냅샷)

> 2026-06-11 기준, 현재 확정된 색상 팔레트. **이 구성은 그대로 유지한다 — 변경 금지.**
> 모든 값의 원본은 `Sources/Theme.swift`이고, 그 외 화면별 고정값은 아래에 따로 기록.

## 핵심 팔레트 (`Theme.swift`)

| 이름 | 값 (sRGB) | HEX 근사 | 용도 |
|------|-----------|----------|------|
| `lumenAccent` | `Color(red: 0.42, green: 0.40, blue: 0.98)` | `#6B66FA` | 앱 틴트(인디고) — 체크마크, 강조 |
| `lumenBG` | `Color(red: 0.07, green: 0.082, blue: 0.105)` | `#12151B` | 전 화면 공통 슬레이트 다크 배경 |
| `lumenCard` | `Color(red: 0.13, green: 0.145, blue: 0.18)` | `#21252E` | 카드/리스트/시트 배경 |

### 그라디언트

- **`heroGradient`** (인디고 강조 — 글리프 하트, 주요 CTA. 앱 아이콘 하트와 동일)
  - `Color(red: 0.46, green: 0.50, blue: 1.0)` `#7580FF` → `Color(red: 0.40, green: 0.40, blue: 0.98)` `#6666FA`
  - 방향: `.topLeading` → `.bottomTrailing`
- **`slateTile`** (슬레이트 타일 — 앱 아이콘 배경과 동일)
  - `Color(red: 0.18, green: 0.21, blue: 0.28)` `#2E3647` → `Color(red: 0.08, green: 0.095, blue: 0.13)` `#141821`
  - 방향: `.topLeading` → `.bottomTrailing`

## 탭바 (`LumenIOSApp.swift` — FloatingTabBar)

| 요소 | 값 |
|------|----|
| 바 배경 | `Color(white: 0.11).opacity(0.9)` (캡슐) |
| 바 테두리 | `.white.opacity(0.07)` |
| 선택 인디케이터 | `Color(white: 0.26)` (둥근 사각형) |
| 선택된 아이콘 | `.white` |
| 비선택 아이콘 | `Color(white: 0.55)` |
| 그림자 | `.black.opacity(0.45)`, radius 22, y 8 |

## 화이트 불투명도 체계 (텍스트/보더 위계)

| 값 | 역할 |
|----|------|
| `.white` (1.0) | 제목, 본문 강조 |
| `.white.opacity(0.85)` | 준강조 텍스트/아이콘 |
| `.white.opacity(0.5~0.65)` | 보조 텍스트 (부제, 카운트, 안내) |
| `.white.opacity(0.3~0.45)` | 희미한 안내문, 플레이스홀더 아이콘 |
| `.white.opacity(0.22~0.25)` | 빈 상태 아이콘, 셰브론 |
| `.white.opacity(0.15~0.18)` | 캡슐/원형 버튼 테두리 |
| `.white.opacity(0.06~0.08)` | 카드 테두리, 썸네일 플레이스홀더 배경, 디바이더 |

## 머티리얼 & 오버레이

- 떠 있는 컨트롤(닫기 ✕, 카운터, 플래시 확인, 정리 시작 버튼, ♥/★ 버튼): `.ultraThinMaterial` 배경 + `.white.opacity(0.15~0.18)` 테두리
- 요약 화면 딤: `.black.opacity(0.30)` + 삭제 후보 모자이크 `blur(radius: 1.5)`
- 홈 패럴랙스 딤: `.black.opacity(0.25)`
- 그림자 공통: `.black.opacity(0.3~0.45)`

## 시맨틱 컬러

- 삭제 버튼 (요약 화면): `Color.red.opacity(0.75)`
- 다크 모드 고정: 모든 최상위 뷰에 `.preferredColorScheme(.dark)`

## 원칙

1. 색은 **인디고(`lumenAccent`/`heroGradient`) 단 하나만 포인트**로 쓰고, 나머지는 전부 슬레이트 + 화이트 불투명도 위계로 표현한다.
2. 새 UI를 추가할 때 새로운 색을 도입하지 않는다 — 위 표의 값만 재사용.
3. 앱 아이콘과 인앱 글리프(`LumenGlyph`)는 같은 `slateTile` + `heroGradient` 조합을 공유한다.
