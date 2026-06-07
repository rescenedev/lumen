# Lumen 기여 가이드

Lumen에 기여해주셔서 감사합니다! 🙏 이 문서는 개발 환경 설정, 코드 구조, 컨벤션, PR 절차를 안내합니다.

Lumen은 **대용량(6만 장+) 라이브러리, 특히 NAS**를 가볍게 다루는 네이티브 macOS 사진 **뷰어/매니저**입니다. 핵심 가치: **빠른 성능 + 비파괴(원본 불변)**.

---

## 사전 준비

- **macOS 14 (Sonoma) 이상**
- **Xcode 불필요** — Command Line Tools만 있으면 됩니다
  ```bash
  xcode-select --install
  ```
- Swift 6.x (Command Line Tools에 포함). 의존성은 [GRDB](https://github.com/groue/GRDB.swift) 하나뿐이며 SwiftPM이 자동으로 가져옵니다.

## 빌드 & 실행

```bash
git clone https://github.com/rescenedev/lumen.git
cd lumen

# 빠른 개발 실행
swift run

# 더블클릭 가능한 .app 빌드 (릴리즈 + 아이콘 + ad-hoc 서명)
./Scripts/make_app.sh
open dist/Lumen.app
```

샘플 이미지로 빠르게 테스트:
```bash
swift Scripts/make_samples.swift "$HOME/LumenSamples"   # EXIF/GPS 심긴 샘플 15장
```

## 테스트

```bash
./Scripts/test.sh        # 또는: swift run LumenTests
```

> **`swift test`가 아닌 이유:** macOS Command Line Tools(Xcode 미설치)에는 XCTest도 swift-testing도 들어있지 않아 `swift test`가 동작하지 않습니다. 그래서 테스트는 **의존성 없는 초경량 어서션 하니스**(`Tests/LumenTests/Harness.swift`)를 쓰는 **실행 타깃**으로 두었고, `swift run LumenTests`로 돌립니다. 실패 시 종료 코드가 0이 아니라 CI에도 그대로 쓸 수 있습니다.

테스트는 순수 로직과 데이터 안전성 표면에 집중합니다: 정렬·필터·리네임 패턴·확장자 인식·중복 탐지(실파일)·내보내기(원본 불변)·메타데이터 store(격리된 인메모리 SQLite, 재시작 후 영속성 포함). 앱 코드는 `LumenKit` 라이브러리에 있고 얇은 `Lumen` 실행 타깃이 이를 띄웁니다 — 덕분에 테스트가 코드와 링크됩니다.

## 프로젝트 구조

```
Sources/Lumen/      ← LumenKit 라이브러리 (앱의 모든 코드, 테스트가 링크하는 대상)
  App/        LumenApp.swift(씬 + 메뉴) · AppLauncher.swift(runLumenApp 진입 브리지)
  Models/     불변 값 타입 (Photo, PhotoMeta, Album, ExifInfo, FilterState, RenamePattern, …)
  Store/      AppModel(중앙 상태) · MetadataStore(SQLite) · AppDatabase · WarmingMonitor
  Services/   스캐너, 썸네일/이미지 캐시, EXIF 인덱서, 내보내기, 중복탐지, iCloud, …
  Views/      SwiftUI 뷰 + Views/Collection/ (AppKit NSCollectionView 그리드)
Sources/LumenMain/  ← Lumen 실행 타깃 (runLumenApp() 호출만 하는 2줄 main.swift)
Tests/LumenTests/   ← 테스트 실행 타깃 + 초경량 하니스 (swift test 대신 swift run)
Scripts/      make_app.sh · test.sh · make_icon.swift · make_samples.swift · Info.plist
```

> **왜 라이브러리 + 얇은 실행 타깃?** SwiftPM에서 실행(executable) 타깃은 다른 타깃이 링크할 수 없습니다. 그래서 모든 코드를 `LumenKit` 라이브러리에 두고, 앱(`Lumen`)과 테스트(`LumenTests`)가 각각 이를 링크합니다.

## 아키텍처 한눈에

- **단일 `AppModel`** (`@Observable`, `@MainActor`)이 라이브러리·뷰 상태를 소유. 서비스는 무상태/캐시 헬퍼, 뷰는 작게 분리.
- **`Photo`는 불변 값 타입** (`Identifiable` by URL). 절대 in-place 변경하지 않음.
- **저장계층**: 사용자 메타데이터(즐겨찾기/별점/라벨/태그/앨범)는 **SQLite(GRDB)** — 행 단위 증분 쓰기. 대용량 사진/EXIF 캐시는 빠른 **plist**.
- **그리드**: 대용량 스크롤을 위해 **AppKit `NSCollectionView`** (진짜 셀 재사용)를 `NSViewRepresentable`로 감쌈. 리스트/지도는 SwiftUI.
- **썸네일**: 2단 캐시(메모리 + 샤딩된 디스크). 백그라운드 전체 워밍이 모든 폴더를 미리 캐싱.

## 코딩 컨벤션

- **작은 파일 / 단일 책임**. 보통 200~400줄, 한 파일에 한 주제.
- **불변성** — 새 값을 만들고 기존 것을 변형하지 않음.
- 주변 코드의 **스타일·주석 밀도·네이밍**을 따를 것.
- 바인딩이 필요한 뷰는 `@Bindable var model = model` 패턴, 그 외엔 `@Environment(AppModel.self)`.
- 모든 에러는 명시적으로 처리. 사용자 대면 메시지는 친절하게.

## ⚡ 성능 원칙 (이 앱의 핵심)

대용량/NAS가 타깃이므로 성능에 민감합니다. 기여 시 지켜주세요:

- **메인 스레드를 막지 마세요.** 디코드·스캔·정렬·DB 일괄쓰기는 백그라운드로.
- **추측하지 말고 측정하세요.** 핫스팟은 `sample <pid>` 또는 Instruments(Time Profiler)로 확인 후 고칩니다.
- **파생 컬렉션은 메모이즈** (`visiblePhotos`, `stats`, 폴더 인덱스 등). 캐시 무효화는 버전 카운터로.
- **재렌더 범위 최소화** — `@Observable` 덕에 읽는 값이 바뀔 때만 갱신됩니다. 불필요한 의존을 만들지 마세요.
- NAS 읽기는 와이어 한계이므로, **캐시 우선 + 점진적 로딩**으로 체감을 개선합니다.

## 기여 절차

1. 레포를 **포크**하고 브랜치 생성: `git checkout -b feat/my-feature`
2. 변경 후 **빌드 + 테스트** 확인: `swift build && ./Scripts/test.sh`
3. 실제 앱으로 **동작 검증**: `./Scripts/make_app.sh && open dist/Lumen.app`
4. **커밋 메시지**는 conventional commits 형식:
   ```
   feat: 새 기능
   fix: 버그 수정
   perf: 성능 개선
   refactor / docs / chore / test
   ```
5. push 후 **PR** 생성 — 무엇을/왜 바꿨는지, 테스트 방법, 스크린샷(UI 변경 시) 포함

## 기여하기 좋은 영역

**기능**
- 🎬 동영상 지원 (현재 이미지 전용)
- ↩️ 휴지통/실행취소 (최근 삭제 복구)
- 🖱️ 사이드바로 드래그앤드롭(앨범/폴더 이동)
- ⭐ 그리드에서 별점/라벨 단축키

**성능 / 확장성**
- 🗄️ 사진 리스트까지 SQLite + 가상화 (수십만 장 대응)
- 🗺️ 지도 핀 클러스터링
- 📊 스캔 진행률 표시

**품질 / 배포**
- ✅ 테스트 확대 — 스캐너(`PhotoScanner`/`IncrementalScanner`)·EXIF 인덱서·AppModel 필터링 로직 (현재는 정렬·필터·리네임·중복·내보내기·메타 store를 커버)
- 🔏 노타라이즈 자동화 (Developer ID 서명 + notarytool)
- 🧹 엣지 케이스 하드닝 (손상 이미지, 권한 거부, NAS 끊김)

> 큰 변경은 먼저 **이슈로 논의**해 방향을 맞춘 뒤 작업하시면 좋습니다.

## 버그 리포트

이슈에 다음을 포함해 주세요:
- macOS 버전, 라이브러리 규모(대략 장수), 저장 위치(로컬/NAS)
- 재현 단계, 기대 동작 vs 실제 동작
- 가능하면 스크린샷 / 콘솔 로그

## 범위 안내 (중요)

Lumen은 본질적으로 **뷰어/매니저**입니다. 편집은 **크롭·리사이즈**로 한정하며(회전/보정 등은 범위 밖), **반드시 비파괴가 기본**이어야 합니다 — 결과는 새 파일로 저장(`ImageEditor`), 원본 덮어쓰기는 명시적 확인을 거친 별도 경로입니다. 그 외 모든 동작도 비파괴적이어야 합니다(휴지통은 복구 가능, 이름변경은 파일명만).

---

즐겁게 기여해 주세요! 질문은 이슈로 남겨주시면 됩니다. 🎉
