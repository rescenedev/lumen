# 설계: Photos Library 소스 (Apple 사진 / iCloud Photos 연동)

> 상태: **설계 (구현 전)** · 브랜치 `feat/photos-library` · 작성 2026-06-07
> 범위: Apple **사진앱 라이브러리**(iCloud Photos로 동기화되는)를 Lumen에서 **읽기 전용**으로 브라우즈/뷰. 기존 파일/NAS 소스는 절대 건드리지 않음.

---

## 1. 목표 / 비목표

**목표**
- 사이드바에 **"Photos Library"** 소스 추가 — 시스템 사진 라이브러리(=iCloud Photos)를 그리드/뷰어로 열람
- iCloud에만 있는 원본은 **온디맨드 다운로드** (지금 NAS/dataless와 동일 UX: 썸네일 즉시, 원본은 필요시)
- 사진앱 **앨범**과 **즐겨찾기** 열람
- 6만+ 에셋에서도 부드럽게 (기존 성능 원칙 유지)

**비목표 (이번 범위 밖)**
- 사진앱으로의 **쓰기**(즐겨찾기 토글/앨범 편집/삭제) — 1차는 읽기 전용
- 픽셀 편집 (앱 전체 원칙: 뷰어/매니저, 편집 없음)
- iCloud Photos **직접**(서버) 접근 — 불가능. 반드시 로컬 사진앱 라이브러리 경유 (§11 참고)

---

## 2. 제약 (반드시 지킬 것)

1. **기존 소스 무손상.** 파일/NAS 기반 `Photo`·폴더 트리·reconcile·캐시 경로를 회귀시키지 않는다. Photos 소스는 *부가* 경로.
2. **비파괴.** 에셋에 대해 휴지통/이름변경/이동/원본수정 같은 파괴적 동작은 **차단**하거나 PhotoKit 안전 경로로만.
3. **대용량.** PHFetchResult의 지연 인덱싱을 활용 — 6만 에셋을 메모리에 다 올리지 않는다.
4. **Xcode 불필요 빌드 유지.** SwiftPM(`swift build`) + CLT만으로 빌드돼야 함. PhotoKit은 시스템 프레임워크라 링크만 하면 됨(추가 의존성 없음).

---

## 3. 핵심 난제

기존 모델은 **파일 `URL` 1급 키** 위에 빽빽이 얹혀 있다:

| 머신 | 키 |
|---|---|
| 선택 (`Photo.ID`) | `url` |
| `ThumbnailCache.thumbnail(for:)` / `cached(for:)` | `url.path` |
| `FullImageLoader.image(for:)` | `url` (ImageIO가 파일 URL을 디코드) |
| `MetadataStore` (즐겨찾기/별점/태그/앨범) | `path` 문자열 |
| 폴더 트리 (`buildFolderTree`) | `photo.folderURL` |

PHAsset은 **파일 URL이 없다.** `localIdentifier`(안정적 문자열)만 있다. 두 모델을 어떻게 한 그리드에 태우느냐가 설계의 전부.

---

## 4. 채택안: "합성 URL" 어댑터 + 분리된 소스

### 4.1 합성 URL

에셋을 다음 URL을 가진 `Photo`로 표현한다:

```
photos-library://<localIdentifier>
```

- `Photo.ID == url` → **선택/그리드/뷰어 변경 0줄.**
- `MetadataStore`는 `url.absoluteString`(또는 path)을 키로 → 별점/태그/앨범 **그대로 동작** (문자열 키라 파일이든 에셋이든 무관).
- `ThumbnailCache`/`FullImageLoader`의 캐시 키(`url.path`)도 유효 → 메모리/디스크 캐시 **재사용**.
- 디코드 단계만 스킴 분기: `photos-library://`면 PHImageManager로, 아니면 기존 ImageIO.

`Photo`에 헬퍼 추가 (파일 모델 불변, 계산 프로퍼티만):

```swift
extension Photo {
    static let assetScheme = "photos-library"
    var isAsset: Bool { url.scheme == Photo.assetScheme }
    var assetLocalIdentifier: String? { isAsset ? url.host ?? String(url.path.dropFirst()) : nil }
}
```

> `localIdentifier`는 `"UUID/L0/001"` 형태로 `/`를 포함할 수 있음 → URL host에 안 들어감. **퍼센트 인코딩**해서 host나 단일 path 컴포넌트로 넣고, 디코딩 헬퍼로 복원한다. (구현 시 라운드트립 단위 테스트 필수 — §11)

### 4.2 왜 별도 소스인가

에셋엔 "폴더"가 없다 → `buildFolderTree`에 끼우지 않는다. 대신 사이드바에 **독립 섹션 "Photos"**:
- `Photos Library` (전체)
- `Photos · Favorites`
- `Photos · 앨범들` (PHAssetCollection)

`allPhotos`(파일/NAS)와 **물리적으로 분리된 `assetPhotos` 컬렉션**으로 둔다 → 파일 reconcile 로직이 에셋을 절대 못 건드림 (제약 1 보장).

---

## 5. 아키텍처 / 신규 컴포넌트

### 5.1 신규 파일

```
Services/
  PhotosLibraryService.swift   PhotoKit 래퍼: 권한, 에셋/앨범 페치, 이미지 요청, 변경 관찰
  PhotosImageLoader.swift      PHImageManager 기반 썸네일/원본 (iCloud 온디맨드)
Models/
  PhotoSource.swift            .files / .photosLibrary 구분 (또는 SidebarItem 확장)
Store/
  PhotosLibraryStore.swift     assetPhotos 캐시 + 앨범 목록 + 권한 상태 (AppModel이 소유)
```

### 5.2 PhotosLibraryService (핵심)

```swift
import Photos

@MainActor
final class PhotosLibraryService {
    // 권한: .notDetermined → request, .authorized/.limited → 진행, 거부 → 안내
    func authorize() async -> PHAuthorizationStatus

    // 전체 에셋 (이미지만; 비디오는 현재 범위 밖). 지연 — PHFetchResult 보관.
    func fetchAllImages() -> PHFetchResult<PHAsset>

    // 앨범 (사용자 앨범 + 스마트앨범 일부: Favorites 등)
    func fetchAlbums() -> [PhotosAlbumRef]
    func assets(in collection: PHAssetCollection) -> PHFetchResult<PHAsset>

    // 변경 관찰 (PHPhotoLibraryChangeObserver) → 라이브러리 갱신 시 재로드
    func startObserving(_ onChange: @escaping () -> Void)
}
```

`PHFetchResult`는 **인덱스 접근 시 지연 로드** → 6만 에셋도 즉시 반환, 스크롤 시 필요한 것만 materialize. 그리드 데이터소스가 인덱스로 `asset(at:)` 접근하게 하면 가장 이상적이지만, 1차는 단순화를 위해 **경량 메타만 뽑아 `[Photo]` 합성 URL 배열**로 변환(localIdentifier + creationDate + pixelSize)해도 됨. (메모리: 6만 × 가벼운 구조 = 수 MB, 허용. 추후 진짜 지연화로 최적화 가능 — §10 Phase 3)

### 5.3 PhotosImageLoader

```swift
func thumbnail(localId: String, maxPixel: Int) async -> NSImage?   // PHImageManager + deliveryMode
func fullImage(localId: String) async -> NSImage?                  // isNetworkAccessAllowed = true (iCloud DL)
```

- `PHCachingImageManager` 사용 → 사진앱 수준의 빠른 썸네일.
- `PHImageRequestOptions.isNetworkAccessAllowed = true` + `progressHandler` → iCloud 원본 온디맨드(현 dataless 패턴과 동형).
- **기존 디스크 썸네일 캐시(3.3GB 샤딩)에 합류**시킬지 결정 필요(§12): PHImageManager가 자체 캐시를 가지므로 중복 저장은 비효율. 1차는 PHImageManager 캐시에 맡기고 메모리 NSCache만 공유 권장.

### 5.4 라우팅 (디코드 분기) — 변경 최소화 지점

`ThumbnailCache.thumbnail(for:)`와 `FullImageLoader.image(for:)` 진입부에서 스킴 분기:

```swift
if url.scheme == Photo.assetScheme, let id = ... {
    return await PhotosImageLoader.shared.thumbnail(localId: id, maxPixel: maxPixel)
}
// 기존 파일 경로 ...
```

→ 그리드 셀(`PhotoCollectionItem.configure`)·뷰어(`ZoomableImage`)는 **수정 불필요** (이미 url만 넘김).

### 5.5 AppModel 통합

- 신규 `@ObservationIgnored assetPhotos: [Photo]` (또는 PhotosLibraryStore에 위임).
- `scoped(_:)`에 케이스 추가: `.photosLibrary` → `assetPhotos`, `.photosAlbum(id)` → 해당 앨범 에셋.
- `gatherUnsorted()`가 소스에 따라 `allPhotos` vs `assetPhotos`를 고름.
- **reconcile/folderTree/watcher는 `assetPhotos`를 절대 안 봄** → 파일 소스 안전.

### 5.6 동작 가드레일 (중요 — 비파괴 보장)

에셋(`photo.isAsset`)에 대해 다음은 **비활성/숨김**:
- 휴지통 이동(⌫), 이름변경, 폴더 이동, "Finder에서 보기", 배경화면 설정(파일 경로 없음)
- 내보내기(원본 복사/zip)는 PhotoKit `requestImageDataAndOrientation`로 **데이터 추출 후** 저장하는 별도 경로 필요(Phase 2)
- 컨텍스트 메뉴/툴바에서 해당 항목 `disabled` (분기: `selection.contains(where: \.isAsset)`)

→ 메뉴 빌더(`PhotoMenuBuilder`, `PhotoContextMenu`)와 `deletionTargets` 등에서 에셋 가드 추가.

---

## 6. 권한 & 엔타이틀먼트

- **Info.plist**: `NSPhotoLibraryUsageDescription` ("Lumen이 사진 라이브러리를 읽어 보여줍니다") — `Scripts/Info.plist`에 추가.
- **샌드박스 시**: `com.apple.security.personal-information.photos-library` 엔타이틀먼트. 현재 앱은 **비샌드박스 ad-hoc 서명** → 비샌드박스에선 usage string만으로 동작(권한 다이얼로그 뜸). 배포(노타라이즈) 단계에서 정리.
- `.limited`(일부만 허용) 상태 처리 — 사용자가 일부 사진만 허용한 경우 그 부분집합만 보임 + "더 선택" 안내.

---

## 7. 성능 설계

- **PHFetchResult 지연** → 초기 로드 즉시 (전체 materialize 안 함).
- **PHCachingImageManager**로 썸네일 — 사진앱과 동급 속도, OS가 캐시 관리.
- iCloud 원본은 **온디맨드 + progress** (전체 다운로드 유발 금지 — DuplicateFinder가 이미 dataless 스킵하는 것과 같은 정신).
- 메모리 NSCache는 파일/에셋 공유, 디스크 썸네일 캐시는 1차엔 에셋 제외(PHImageManager 자체 캐시 사용).
- 정렬/필터는 기존 메모이즈 그대로 (합성 URL `Photo`라 `SortOrder`/`FilterState` 재사용).

---

## 8. 데이터 흐름

**브라우즈**
```
사이드바 "Photos Library" 선택
  → committedSidebar = .photosLibrary
  → (최초) PhotosLibraryService.authorize() → fetchAllImages()
  → PHAsset[] → [Photo(url: photos-library://<id>, creationDate, ...)] = assetPhotos
  → scoped(.photosLibrary) → visiblePhotos → 그리드(기존 NSCollectionView)
```

**셀 렌더 (변경 없음)**
```
PhotoCollectionItem.configure(photo)
  → ThumbnailCache.thumbnail(for: photo.url)
     → [스킴=photos-library] PhotosImageLoader.thumbnail(localId:)  ← 신규 분기
     → [그 외] 기존 ImageIO 경로
```

**뷰어 (변경 없음)**
```
openViewer(photo) → ZoomableImage → FullImageLoader.image(for: photo.url)
  → [스킴 분기] PhotosImageLoader.fullImage(localId:) (iCloud DL) / 기존
```

---

## 9. 단계별 (Phasing)

| Phase | 내용 | 산출 |
|---|---|---|
| **1 (MVP)** | 권한 → 전체 사진 브라우즈 → 뷰어(iCloud 온디맨드) → 우리 메타(별점/태그) 부착 | 읽기 전용 열람 |
| **2** | 앨범 + Favorites(읽기) · 에셋 가드레일(파괴 동작 차단) · 에셋 내보내기(데이터 추출) | 실사용 가능 |
| **3** | PHFetchResult 진짜 지연 데이터소스(메모리 최적) · 변경 관찰 실시간 반영 · `.limited` UX | 6만+ 견고 |
| **4 (선택)** | 사진앱으로 **쓰기**(즐겨찾기 토글 등, PHPhotoLibrary change request) | 양방향 |

---

## 10. 파일별 변경 목록

**신규**
- `Sources/Lumen/Services/PhotosLibraryService.swift`
- `Sources/Lumen/Services/PhotosImageLoader.swift`
- `Sources/Lumen/Store/PhotosLibraryStore.swift`
- `Sources/Lumen/Models/PhotoSource.swift` (또는 SidebarItem 확장만)

**수정 (부가만, 회귀 0 목표)**
- `Models/Photo.swift` — `isAsset`/`assetLocalIdentifier` 계산 프로퍼티 (저장 프로퍼티 불변)
- `Models/SidebarItem.swift` — `.photosLibrary`, `.photosAlbum(String)` 케이스 + id/아이콘
- `Services/ThumbnailCache.swift` — `thumbnail(for:)` 진입 스킴 분기
- `Services/FullImageLoader.swift` — `image(for:)` 진입 스킴 분기
- `Store/AppModel.swift` — `assetPhotos` 소유, `scoped`/`gatherUnsorted` 케이스, 에셋 가드(`deletionTargets` 등)
- `Views/SidebarView.swift` — "Photos" 섹션
- `Views/Collection/PhotoMenuBuilder.swift` + `Views/PhotoContextMenu.swift` — 에셋 파괴 동작 disabled
- `Scripts/Info.plist` — `NSPhotoLibraryUsageDescription`

---

## 11. 테스트 전략

PhotoKit은 실제 라이브러리/권한이 필요 → 자체 하니스(`swift run LumenTests`)로 **순수 부분만** 커버:
- **합성 URL 라운드트립**: `localIdentifier ↔ photos-library://` 인코딩/디코딩 (특히 `/` 포함 ID) — 회귀 위험 1순위
- `Photo.isAsset` / `assetLocalIdentifier` 분기
- `scoped(.photosLibrary)`가 `assetPhotos`만 반환하고 파일 소스와 안 섞이는지 (주입 가능하게 설계)
- 에셋 가드: `deletionTargets`/내보내기 타깃에서 에셋 제외되는지
- PhotoKit 호출 자체는 **프로토콜로 추상화**(`PhotosBackend`)해 목으로 대체 → 라우팅 로직 단위 테스트 가능

실제 PHImageManager·권한 흐름은 **수동 QA**(기존 키보드/포커스와 같은 카테고리).

---

## 12. 결정 필요 (사용자 확인)

1. **디스크 썸네일 캐시 공유?** 에셋 썸네일을 기존 3.3GB 샤딩 캐시에 같이 저장할지 vs PHImageManager 자체 캐시에 맡길지. → *권장: 1차는 PHImageManager 캐시* (중복 저장 회피).
2. **에셋 내보내기 범위.** Phase 2에서 원본 데이터 추출 내보내기까지 갈지, 1차는 "사진앱에서 열기"만 제공할지.
3. **비디오.** 현재 이미지 전용. 사진 라이브러리엔 비디오가 많음 — 일단 **이미지만 페치**(predicate `mediaType == .image`)로 시작, 비디오는 별도 과제.
4. **즐겨찾기 의미.** 사진앱 `isFavorite`(읽기) vs Lumen 자체 즐겨찾기 — 1차는 **분리**(우리 메타는 localIdentifier 키), 양방향 동기화는 Phase 4.
5. **샌드박스/배포.** 노타라이즈와 함께 엔타이틀먼트 정리 시점.

---

## 13. 리스크

- **합성 URL 누수**: 에셋 URL이 파일 동작 경로로 새면(예: 어딘가 `url.path`로 파일 접근) 크래시/오작동. → 가드레일 + 테스트로 차단, 그리고 "에셋은 파일 동작 불가" 단일 분기점(`isAsset`)으로 집약.
- **localIdentifier 안정성**: 대체로 안정적이나 라이브러리 재구축 시 바뀔 수 있음 → 우리 메타가 고아화. (파일 path도 같은 한계라 동급 리스크)
- **권한 거부/`.limited`**: 빈 상태·부분 상태 UX 필요.
- **메모리**: Phase 1에서 6만 `Photo` 합성(수 MB)은 OK. 진짜 대형(수십만)은 Phase 3 지연 데이터소스 필요.

---

## 부록: 한 줄 요약

> **에셋을 `photos-library://<id>` 합성 URL로 감싸 기존 URL 기반 머신(선택·그리드·뷰어·메타·캐시)을 그대로 재사용하고, 디코드/소스/파괴동작 세 지점에만 스킴 분기를 넣는다. 파일 소스와는 컬렉션을 물리 분리해 reconcile 회귀를 원천 차단.**
