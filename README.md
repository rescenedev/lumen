# Lumen — macOS 사진 뷰어 & 매니저

대용량(6만 장 이상) 사진 라이브러리, 특히 **NAS**에 있는 것도 가볍게 다루는 **네이티브 macOS** 사진 뷰어/매니저입니다. SwiftUI + AppKit으로 제작했고, [fayazara/macos-app-skills](https://github.com/fayazara/macos-app-skills)의 네이티브 패턴을 기반으로 합니다.

> **범위 안내:** Lumen은 **뷰어/매니저**입니다 — 이미지 픽셀은 절대 건드리지 않습니다(크롭/회전/보정 없음). 모든 동작은 비파괴적입니다(휴지통은 복구 가능, 이름변경은 파일명만 변경).

macOS 14(Sonoma) 이상 · Swift 6.3 (개발/테스트는 macOS 26 “Tahoe”).

🔗 랜딩 페이지: https://rescenedev.github.io/lumen

## 기능

**라이브러리 & 정리**
- 폴더/이미지 추가 (⌘O, **＋**, 드래그앤드롭). JPEG·PNG·HEIC·TIFF·GIF·WebP·AVIF·PSD 및 RAW(CR2/CR3·NEF·ARW·DNG·ORF…) 재귀 스캔
- **앨범** 생성/이름변경/삭제, 선택 추가/제거
- **태그**, **색상 라벨**(Finder 스타일), 각각 사이드바 섹션
- **별점**(0–5) — 뷰어에서 `1`~`5` 키, 인스펙터에서 별 클릭
- **스마트 모음** — 전체·즐겨찾기·최근 추가·오늘 날짜·중복
- **폴더 트리**(기본 계층형), **실시간 폴더 감시**(FSEvents)로 추가/삭제 자동 반영
- 메타데이터(즐겨찾기/별점/라벨/태그/앨범)는 `~/Library/Application Support/Lumen`에 영구 저장

**뷰**
- **그리드**, **리스트**, **지도**(MapKit, GPS 사진 핀) — ⌘1 / ⌘2 / ⌘3
- 적응형 그리드 + 하단 크기 슬라이더, 월별 타임라인 그룹
- 다중 선택: 클릭, ⌘클릭 토글, ⇧클릭 범위, ⌘A, Esc 해제
- 정렬(날짜/이름/크기), **필터**(종류·별점·라벨·즐겨찾기·위치·카메라)
- **검색**: 파일명 + 태그 + 카메라 모델(예: “SONY”)

**뷰어**
- 핀치/스크롤/더블클릭 **줌**, 드래그 **팬**, 좌우 **이전/다음 썸네일 미리보기**
- **EXIF 오버레이**(`i`), 인라인 **별점**, **2장 비교**(2개 선택)
- 슬라이드쇼(`P`), 즐겨찾기(`f`), 휴지통(⌫)
- **Space** = 즐겨찾기 추가 + 다음 사진으로 (빠른 컬링; 이미 즐겨찾기면 해제)

**동작**
- **휴지통 이동**(⌫ / ⌘⌫) 확인 후, 다중 선택 지원
- **공유**(시스템 공유 시트), **내보내기**(원본/리사이즈/zip), **배경화면 설정**
- **일괄 이름변경**(`{n}` 패턴 + 미리보기), **중복 찾기**(크기+내용 해시)
- Quick Look(Space), Finder에서 보기, 복사, 기본 앱으로 열기

**인스펙터**
- 별점/라벨/태그 편집 + 앨범 추가, 메타 정보 **클릭하면 즉시 복사**
- 파일 정보, 카메라 EXIF, GPS 좌표 + “지도에서 보기”
- 다중 선택 요약 + 일괄 동작

**성능 & 네이티브 통합**
- 2단 썸네일 캐시(메모리 + **디스크**, 재실행에도 유지) + **백그라운드 전체 워밍**
- 폴더 인덱스 · 메모이즈된 목록 · 디바운스 사이드바 내비
- 지연 EXIF 인덱싱(지도/필터 쓸 때만) · 증분 mtime 스캔 · 라이브러리/EXIF 캐시로 즉시 재실행
- `NavigationSplitView` + 인스펙터 패널, Quick Look, `NSSharingServicePicker`, `NSWorkspace`, 설정 창(⌘,)

## 설치 (Homebrew)

```bash
brew tap rescenedev/tap
brew install --cask lumen-photos
```

cask 이름은 `lumen-photos`입니다(`lumen`은 homebrew-cask에 다른 앱이 이미 사용 중). 노타라이즈되지 않은 ad-hoc 서명이라, 첫 실행 시 macOS가 막으면 **우클릭 → 열기** 하거나
`xattr -dr com.apple.quarantine "/Applications/Lumen.app"`.

## 소스로 빌드 & 실행

```bash
# 빠른 개발 실행:
swift run

# 더블클릭 가능한 .app 빌드(릴리즈 + 아이콘 + ad-hoc 서명):
./Scripts/make_app.sh
open dist/Lumen.app
```

Xcode 없이 **Command Line Tools만** 있으면 됩니다(Swift Package Manager로 빌드).

## 샘플 이미지로 체험

```bash
swift Scripts/make_samples.swift "$HOME/LumenSamples"   # EXIF/GPS 심긴 샘플 15장
open dist/Lumen.app                                      # ⌘O로 폴더 선택
```

## 프로젝트 구조

```
Sources/Lumen/
  App/          LumenApp.swift          @main 씬 + 메뉴 커맨드
  Models/       Photo, SortOrder, SidebarItem, ViewMode, PhotoMeta, Album, ExifInfo, FilterState, FolderNode
  Store/        AppModel(중앙 상태), MetadataStore, WarmingMonitor
  Services/     PhotoScanner, IncrementalScanner, ThumbnailCache, FullImageLoader,
                MetadataReader, ExifIndexer, FolderWatcher, Exporter, DuplicateFinder,
                LibraryCache, QuickLookThumbnailer, iCloudDownloader
  Views/        ContentView, SidebarView, PhotoBrowserView, PhotoGridView/ListView/MapView,
                ThumbnailCell, AsyncThumbnail, ViewerView, ZoomableImage, InspectorView,
                MetadataEditor, FilterMenu, 각종 시트/메뉴
Scripts/        make_app.sh, make_icon.swift, make_samples.swift, Info.plist
```

아키텍처: 중앙 `AppModel` 하나가 라이브러리와 뷰 상태를 소유, 서비스는 무상태/캐시 헬퍼, 뷰는 작게 분리. `Photo`는 불변 값 타입.

## 기여 & 라이선스

기여 환영합니다 — [CONTRIBUTING.md](CONTRIBUTING.md)를 봐주세요. [MIT 라이선스](LICENSE).
