# Wix Live Test Report

Generated on March 27, 2026.

Source of row counts:
- Synced live files under `/Users/shayco/API2File-Data/wix`
- Live Wix API counts for resources added in the updated source adapter but not yet materialized in the existing on-disk mirror

Source of test coverage:
- `/Users/shayco/API2File/Tests/API2FileCoreTests/Integration/WixLiveE2ETests.swift`

## Summary

| File | Current rows | Pull tested | Create tested | Update tested | Delete tested | Notes |
| --- | ---: | :---: | :---: | :---: | :---: | --- |
| `contacts.csv` | 4 | Yes | Yes | Yes | Yes | Live CRUD coverage added |
| `products.csv` | 14 | Yes | Yes | Yes | Yes | Live CRUD coverage added |
| `cms/projects.csv` | 5 | Yes | Yes | Yes | Yes | Includes server-create to local file check |
| `cms/todos.csv` | 11 | Yes | Yes | Yes | Yes | Includes server-create and server-update to local file checks |
| `cms/events.csv` | 1 | Yes | No | No | No | Read-only coverage today |
| `events.csv` | 1 | Yes | No | Yes | No | Live update coverage added; create/delete still not covered |
| `bookings/services.csv` | 0 in main mirror, 1 live service | Yes | Yes | Yes | Yes | Live CRUD coverage added |
| `bookings/appointments.csv` | 0 | Yes | No | No | No | Empty file is currently expected/allowed |
| `groups.csv` | 1 live group | Yes | Yes | Yes | Yes | Covered through live harness; not yet present in main on-disk mirror |
| `blog/*.md` | 5 files | Yes | Yes | Yes | Yes | Live CRUD coverage added for blog posts |
| `blog/categories.csv` | 1 | Yes | Yes | Yes | Yes | Live CRUD coverage added |
| `blog/tags.csv` | Missing in main mirror | Yes | Yes | No | Yes | Empty collection is seeded in tests; server-create also verified into temp local file |
| `comments.csv` | 0 | Yes | No | No | No | Empty file pull coverage only |
| `pro-gallery/*` | 12 live assets | Yes | No | No | No | Media Manager-backed pull coverage; not yet present in main on-disk mirror |
| `pdf-viewer/*` | 0 live assets | Yes | Yes | No | Yes | Upload/pull/delete covered through Media Manager-backed flow |
| `wix-video/*` | 0 live assets | Yes | Yes | No | Yes | Upload/pull/delete covered through Media Manager-backed flow |
| `wix-music-podcasts/*` | 0 live assets | Yes | Yes | No | Yes | Upload/pull/delete covered through Media Manager-backed flow |
| `events/rsvps.csv` | 0 | Yes | No | No | No | Empty file pull coverage only |
| `events/tickets.csv` | 0 | Yes | No | No | No | Empty file pull coverage only |
| `restaurant/menus.csv` | 1 | Yes | Yes | Skipped | Yes | Pull/create/delete work; update endpoint returned 404 on this site |
| `restaurant/reservations.csv` | Unavailable | Skipped | No | No | No | Endpoint returns 404 on this site |
| `restaurant/orders.csv` | Unavailable | Skipped | No | No | No | Endpoint returns 404 on this site |

## Detailed Coverage

### `contacts.csv`

- Pull: `testContacts_Pull_ReturnsCSVWithExpectedFields`
- Create: `testContacts_Create_NewContact_AppearsOnServer`
- Update: `testContacts_Update_ModifyName_ReflectedOnServer`
- Delete: `testContacts_Delete_RemoveContact_DeletedFromServer`

### `products.csv`

- Pull: `testProducts_Pull_ReturnsCSVWithProductData`
- Pull known data: `testProducts_Pull_ContainsKnownProducts`
- Create: `testProducts_Create_NewProduct_AppearsOnServer`
- Update: `testProducts_Update_ModifyName_ReflectedOnServer`
- Update revision behavior: `testProducts_Update_RevisionIncrementsAfterPush`
- Delete: `testProducts_Delete_RemoveProduct_DeletedFromServer`

### `cms/projects.csv`

- Pull: `testCMSProjects_Pull_ReturnsCSVWithCorrectFields`
- Create: `testCMSProjects_Create_NewProject_AppearsOnServer`
- Update: `testCMSProjects_Update_ModifyName_ReflectedOnServer`
- Delete: `testCMSProjects_Delete_RemoveProject_DeletedFromServer`
- Server to file: `testCMSProjects_ServerCreate_ReflectedInLocalFile`

### `cms/todos.csv`

- Pull: `testCMSTodos_Pull_ReturnsCSVWithExpectedColumns`
- Pull known data: `testCMSTodos_Pull_ContainsKnownRecords`
- Create: `testCMSTodos_Create_NewRow_AppearsOnServer`
- Update: `testCMSTodos_Update_ModifyTitle_ReflectedOnServer`
- Delete: `testCMSTodos_Delete_RemoveRow_DeletedFromServer`
- Full round trip: `testCMSTodos_RoundTrip_CreateUpdateDelete`
- Server to file create: `testCMSTodos_ServerChange_ReflectedInLocalFile`
- Server to file update: `testCMSTodos_ServerUpdate_ReflectedInLocalFile`

### `cms/events.csv`

- Pull: `testCMSEvents_Pull_ReturnsCSVWithExpectedFields`
- Create: not covered
- Update: not covered
- Delete: not covered

### `events.csv`

- Pull: `testEvents_Pull_ReturnsCSVWithExpectedFields`
- Update: `testEvents_Update_ModifyTitle_ReflectedOnServer`
- Create: not covered
- Delete: not covered

### `bookings/services.csv`

- Pull: `testBookingsServices_Pull_WritesExpectedFile`
- Create: `testBookingsServices_Create_NewService_AppearsOnServer`
- Update: `testBookingsServices_Update_ModifyName_ReflectedOnServer`
- Delete: `testBookingsServices_Delete_RemoveService_DeletedFromServer`
- Current on-disk mirror file is empty, but the live API currently returns 1 service

### `bookings/appointments.csv`

- Pull: `testBookingsAppointments_Pull_WritesExpectedFile`
- Create: not covered
- Update: not covered
- Delete: not covered
- Current live file is empty, and the test allows that

### `groups.csv`

- Pull: `testGroups_Pull_ReturnsCSVWithExpectedFields`
- Create: `testGroups_Create_NewGroup_AppearsOnServer`
- Update: `testGroups_Update_ModifyName_ReflectedOnServer`
- Delete: `testGroups_Delete_RemoveGroup_DeletedFromServer`
- Live API currently has 1 group
- The updated source adapter supports this resource, but the existing configured Wix mirror has not been regenerated yet, so `groups.csv` is not present in `/Users/shayco/API2File-Data/wix`

### `blog/*.md`

- Pull: `testBlogPosts_Pull_WritesMarkdownFilesWithFrontMatter`
- Create: `testBlogPosts_Create_NewPost_AppearsOnServer`
- Update: `testBlogPosts_Update_ModifyTitle_ReflectedOnServer`
- Delete: `testBlogPosts_Delete_RemovePost_DeletedFromServer`

### `blog/categories.csv`

- Pull: `testBlogCategories_Pull_ReturnsCSVWithExpectedFields`
- Create: `testBlogCategories_Create_NewCategory_AppearsOnServer`
- Update: `testBlogCategories_Update_ModifyLabel_ReflectedOnServer`
- Delete: `testBlogCategories_Delete_RemoveCategory_DeletedFromServer`

### `blog/tags.csv`

- Pull: `testBlogTags_Pull_WritesExpectedFile`
- Create: `testBlogTags_Create_NewTag_AppearsOnServer`
- Delete: `testBlogTags_Delete_RemoveTag_DeletedFromServer`
- Server to file create: `testBlogTags_ServerCreate_ReflectedInLocalFile`
- Update: not covered
  Wix blog tag create/delete work with the current live API, but update does not map cleanly to the current adapter contract yet.

### `comments.csv`

- Pull: `testComments_Pull_WritesExpectedFile`
- Create: not covered
- Update: not covered
- Delete: not covered
- Current live file is empty, and the test allows that

### `pro-gallery/*`

- Pull: `testProGallery_Pull_DownloadsImages`
- Create: not covered
- Update: not covered
- Delete: not covered
- Live API currently has 12 image assets
- This is modeled via Media Manager because the dedicated Pro Gallery REST endpoint returned a Wix-side `500` on this site during investigation

### `pdf-viewer/*`

- Pull: `testPDFViewer_Pull_AllowsEmptyDirectory`
- Create/upload: `testPDFViewer_Upload_Pull_Delete`
- Update: not covered
- Delete: `testPDFViewer_Upload_Pull_Delete`
- Live API currently has 0 PDF assets after test cleanup
- This is modeled via Media Manager-backed document assets

### `wix-video/*`

- Pull: `testWixVideo_Pull_AllowsEmptyDirectory`
- Create/upload: `testWixVideo_Upload_Pull_Delete`
- Update: not covered
- Delete: `testWixVideo_Upload_Pull_Delete`
- Live API currently has 0 video assets after test cleanup
- This is modeled via Media Manager-backed video assets

### `wix-music-podcasts/*`

- Pull: `testWixMusicPodcasts_Pull_AllowsEmptyDirectory`
- Create/upload: `testWixMusicPodcasts_Upload_Pull_Delete`
- Update: not covered
- Delete: `testWixMusicPodcasts_Upload_Pull_Delete`
- Live API currently has 0 audio assets after test cleanup
- Important adapter note:
  Wix returns uploaded MP3 files as `mediaType: "AUDIO"`, so the source adapter now filters on `AUDIO` rather than `MUSIC`

### `events/rsvps.csv`

- Pull: `testEventsRSVPs_Pull_WritesExpectedFile`
- Create: not covered
- Update: not covered
- Delete: not covered
- Current live file is empty, and the test allows that

### `events/tickets.csv`

- Pull: `testEventsTickets_Pull_WritesExpectedFile`
- Create: not covered
- Update: not covered
- Delete: not covered
- Current live file is empty, and the test allows that

### `restaurant/*`

- Menus pull: `testRestaurantMenus_Pull_WritesExpectedFileWhenInstalled`
- Menus create: `testRestaurantMenus_Create_NewMenu_AppearsOnServer`
- Menus delete: `testRestaurantMenus_Delete_RemoveMenu_DeletedFromServer`
- Menus update: skipped
  Wix restaurant menu update endpoints returned `404` on this site during live retries.
- Reservations pull: `testRestaurantReservations_Pull_WritesExpectedFileWhenInstalled`
- Orders pull: `testRestaurantOrders_Pull_WritesExpectedFileWhenInstalled`
- Current site status:
  `restaurant-reservations` and `restaurant-orders` skip because their endpoints return `404` on this site.

## Gaps

- `cms/events.csv` still has pull-only coverage.
- `events.csv` now has pull + update coverage, but not create/delete.
- `bookings/appointments.csv` still has pull-only coverage.
- `groups.csv` is fully covered in the live harness, but the existing configured Wix mirror still needs an adapter refresh or reconnect before that file appears under `/Users/shayco/API2File-Data/wix`.
- `comments.csv`, `events/rsvps.csv`, and `events/tickets.csv` still have pull-only coverage because their live create/update shapes require more site-specific context than the current adapter exposes.
- `blog/tags.csv` now has create/delete coverage, but not update coverage.
- `pro-gallery/*`, `pdf-viewer/*`, `wix-video/*`, and `wix-music-podcasts/*` are covered through the updated source adapter and live harness, but those directories are not yet present in the existing configured Wix mirror.
- `restaurant/menus.csv` has pull/create/delete coverage, but update returned `404` on this site.
- `restaurant/reservations.csv` and `restaurant/orders.csv` remain environment-gated on this Wix site and skip instead of failing.
