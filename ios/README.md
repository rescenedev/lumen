# Lumen for iOS

**넘기다 보면, 사진이 정리돼요.** 사진 앱처럼 부드럽게 넘기고, 핀치로 줌하고,
탭으로 스텝하면서 — 마음에 드는 사진만 ♥로 보관하고, ✕는 확인 후 한 번에 삭제하는
네이티브 iOS 사진 정리 앱입니다.

🌐 **소개 페이지**: https://rescenedev.github.io/lumen/lumen-ios/

> [!NOTE]
> 이 저장소는 [`rescenedev/lumen`](https://github.com/rescenedev/lumen)의 `ios/`
> 디렉토리를 자동 동기화하는 **읽기 전용 미러**입니다.
> 이슈와 PR은 [본 저장소](https://github.com/rescenedev/lumen)로 보내주세요.

## 특징

- **제스처가 전부** — 좌우 페이지 스와이프, 화면 가장자리 탭으로 스텝, 핀치 줌(+더블탭),
  위로 올려 즐겨찾기, ♥ 보관, ✕ 삭제 후보
- **수십만 장도 즉시** — 전체를 순회하지 않는 쿼리 기반 로딩, 보이는 셀만 그리는
  네이티브 그리드, 스크롤을 앞지르는 프리페칭
- **비파괴** — 보관은 즉시 'Lumen' 앨범에(앱이 꺼져도 안전), 삭제는 항상 시스템 확인 후
- **Apple 생태계 그대로** — 즐겨찾기·앨범 모두 Apple 사진(PhotoKit) 표준 사용

## 빌드 (무료 Apple ID로 내 폰에 설치)

```bash
git clone https://github.com/rescenedev/lumen-ios.git
cd lumen-ios
xcodegen generate        # brew install xcodegen
open LumenIOS.xcodeproj
```

1. Xcode에서 Signing & Capabilities → 본인 Apple ID 팀 선택
2. 아이폰 연결 → `⌘R`
3. 첫 실행 시: 설정 → 일반 → VPN 및 기기 관리 → 개발자 앱 신뢰

요구사항: iOS 17+, Xcode 16+, 사진 라이브러리 접근 권한.
`LumenIOS.xcodeproj/`는 커밋되지 않습니다 — `project.yml`에서 재생성하세요.

## 구조

```
Sources/
  LumenIOSApp.swift      앱 엔트리
  PhotoLibrary.swift     PhotoKit 데이터 레이어 (lazy fetch, 프리워밍, 변경 감지)
  LibraryView.swift      홈 — 정리할 앨범 고르기
  AlbumGalleryView.swift 앨범 갤러리 (사진 그리드)
  PhotoGridView.swift    UICollectionView 그리드 (연속 핀치 줌, 프리페칭)
  OrganizeView.swift     뷰어/정리 — 페이지 스와이프, 핀치 줌, ♥/✕
AppStore/                App Store 메타데이터·스크린샷
```

## 라이선스

MIT — macOS 버전은 [rescenedev/lumen](https://github.com/rescenedev/lumen),
소개 페이지는 [여기](https://rescenedev.github.io/lumen/lumen-ios/).
