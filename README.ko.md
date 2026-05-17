[中文](README.md) | [日本語](README.ja.md) | [**한국어**](README.ko.md) | [English](README.en.md)

# ClipMate - macOS 클립보드 매니저

macOS Paste 앱의 고충실도 클론. 순수 네이티브 Swift 6 + SwiftUI/AppKit로 개발.

![ClipMate 미리보기](assets/screenshots/preview.jpg)

> ✅ **Xcode 불필요!** `swift build` + `build.sh`로 직접 컴파일 및 패키징. Apple Silicon과 Intel Mac 모두 지원.

## 기능

| 모듈 | 기능 | 상태 |
|------|------|------|
| 📋 클립보드 모니터링 | 텍스트, 이미지, 파일, 링크, 리치 텍스트 실시간 모니터링 | ✅ |
| 📜 기록 패널 | 가로 스크롤 카드 목록, 고충실도 Paste UI, 주색 추출 | ✅ |
| 🔍 전문 검색 | FTS5 전문 인덱스, 300ms 디바운스 실시간 검색 | ✅ |
| 📌 핀보드 | 고정 보드 그룹 관리, 색상 라벨, 우클릭 삭제/이름 변경 | ✅ |
| ⭐ 즐겨찾기 | 중요한 클립보드 항목 북마크 | ✅ |
| ⌨️ 전역 단축키 | ⌘⇧V로 패널 토글 (Carbon RegisterEventHotKey) | ✅ |
| 🚫 앱 제외 | 비밀번호 관리자 등 민감한 앱 제외 | ✅ |
| ⚙️ 환경설정 | 로그인 시 실행 / Dock 아이콘 / 알림 / 스토리지 관리 / 데이터 내보내기 | ✅ |
| ☁️ iCloud 동기화 | iCloud Drive ubiquity 컨테이너 동기화 (Xcode 서명 필요) | ✅ |
| 🔐 접근성 감지 | 권한 상실 시 자동 알림, 재설치 후 재인증 가이드 | ✅ |
| 🎨 앱 아이콘 | 메뉴 막대 + Dock 아이콘, 전체 크기 icns | ✅ |

## 빌드 및 실행

### 방법 1: build.sh 원클릭 빌드 (권장)

```bash
cd PasteClone

# 유니버설 바이너리 (기본값, M시리즈 + Intel Mac 모두 지원)
./build.sh

# Apple Silicon 전용
./build.sh --arch arm64

# Intel Mac 전용
./build.sh --arch x86_64
```

빌드 산출물은 `.build/` 디렉토리에 생성됩니다:

| 산출물 | 설명 |
|--------|------|
| `ClipMate-1.0.0-Universal.dmg` | 유니버설 바이너리 (기본값) |
| `ClipMate-1.0.0-ARM.dmg` | Apple Silicon 전용 |
| `ClipMate-1.0.0-Intel.dmg` | Intel Mac 전용 |

**하위 명령어**:

```bash
./build.sh build       # 컴파일만
./build.sh bundle      # 컴파일 + .app 패키징 + 서명
./build.sh dmg         # 전체 파이프라인 (기본값)
./build.sh run         # 컴파일 후 실행
./build.sh clean       # 빌드 산출물 정리
```

### 방법 2: 수동 빌드

```bash
# 릴리스 빌드
swift build -c release

# 실행
.build/release/ClipMate
```

### 방법 3: Xcode (Xcode + 개발자 계정 필요)

```bash
open PasteClone.xcodeproj
# ⌘R로 실행
```

> ⚠️ iCloud 동기화 기능은 유효한 Provisioning Profile과 함께 Xcode를 통해 빌드해야 합니다. `build.sh` 빌드는 실행 실패를 방지하기 위해 iCloud 엔타이틀먼트를 자동으로 제거합니다.

## 의존성

| 라이브러리 | 버전 | 용도 |
|-----------|------|------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.29 | SQLite ORM + FTS5 전문 검색 |

## 기술 하이라이트

- **클립보드 모니터링**: `NSPasteboard.changeCount` 폴링 방식 (0.5초 간격), 제외 규칙 지원
- **UI**: `NSPanel` HUD 서리 유리 배경 + SwiftUI 가로 카드 갤러리
- **데이터**: GRDB + FTS5 전문 인덱스, `~/Library/Application Support/ClipMate/`에 저장
- **전역 단축키**: Carbon `RegisterEventHotKey` API (⌘⇧V), LSUIElement 모드
- **멀티 아키텍처**: `swift build --arch` + `lipo -create`로 유니버설 바이너리 생성
- **코드 서명**: PlistBuddy로 iCloud 엔타이틀먼트 필터링 후 codesign, error 153 방지
- **Swift 6**: `@MainActor` 전면 채택으로 동시성 안전성 확보, strict concurrency 모드

## 시스템 요구사항

- **최소**: macOS 14.0 (Sonoma)
- **권장**: macOS 15.0 (Sequoia)

## 권한 안내

최초 실행 시 **시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용** 에서 권한을 부여해야 합니다. 권한이 없으면 빠른 붙여넣기 기능이 작동하지 않습니다. 재설치 후에는 기존 항목을 먼저 삭제한 후 다시 추가해야 합니다.

## 라이선스

MIT License
