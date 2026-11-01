import Foundation

/// 随 App 分发的 yt-dlp 插件，启动搜索前写到 App Support/Video2Text/bin/yt-dlp-plugins/
///
/// yt-dlp 内置的 B 站搜索（bilisearch）调用的接口本身支持排序，返回值里也有标题、播放量，
/// 但它既不传 order 参数，也只保留视频链接。插件沿用同一接口和同样的 buvid3 处理，
/// 只多传 order，并把标题、播放量、时长、UP 主一起带回来。
enum YtDlpPlugins {
    /// 传给 --plugin-dirs 的目录：其下每个子目录是一个含 yt_dlp_plugins 的插件包
    static var root: URL { AppPaths.bin.appendingPathComponent("yt-dlp-plugins", isDirectory: true) }

    private static var biliSortFile: URL {
        root.appendingPathComponent("v2t/yt_dlp_plugins/extractor/bilisort.py")
    }

    /// 内容有变化才重写，返回插件根目录
    static func ensureInstalled() throws -> URL {
        let file = biliSortFile
        if (try? String(contentsOf: file, encoding: .utf8)) != biliSortSource {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try biliSortSource.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private static let biliSortSource = #"""
    # 视频转文字 App 自动生成，请勿手改（App 会覆盖）
    # B站搜索排序：沿用 yt-dlp 内置 BiliBiliSearchIE 的请求方式，只多传 order 参数，并保留标题、播放量等字段
    import itertools
    import uuid

    from yt_dlp.extractor.common import SearchInfoExtractor
    from yt_dlp.utils import clean_html, int_or_none, parse_duration


    class _BiliSortedSearchBaseIE(SearchInfoExtractor):
        _MAX_RESULTS = 1000
        _ORDER = 'totalrank'

        def _search_results(self, query):
            if not self._get_cookies('https://api.bilibili.com').get('buvid3'):
                self._set_cookie('.bilibili.com', 'buvid3', f'{uuid.uuid4()}infoc')
            for page_num in itertools.count(1):
                videos = self._download_json(
                    'https://api.bilibili.com/x/web-interface/search/type', query,
                    note=f'Extracting results from page {page_num}', query={
                        'keyword': query,
                        'page': page_num,
                        'search_type': 'video',
                        'order': self._ORDER,
                    })['data'].get('result')
                if not videos:
                    break
                for video in videos:
                    yield self.url_result(
                        video['arcurl'], 'BiliBili', str(video['aid']),
                        clean_html(video.get('title')),
                        view_count=int_or_none(video.get('play')),
                        duration=parse_duration(video.get('duration')),
                        uploader=video.get('author'),
                        timestamp=int_or_none(video.get('pubdate')))


    class BiliSortClickIE(_BiliSortedSearchBaseIE):
        IE_DESC = 'Bilibili search, most played'
        _SEARCH_KEY = 'bilisortclick'
        _ORDER = 'click'


    class BiliSortPubdateIE(_BiliSortedSearchBaseIE):
        IE_DESC = 'Bilibili search, newest'
        _SEARCH_KEY = 'bilisortpubdate'
        _ORDER = 'pubdate'


    class BiliSortRankIE(_BiliSortedSearchBaseIE):
        IE_DESC = 'Bilibili search, relevance'
        _SEARCH_KEY = 'bilisortrank'
        _ORDER = 'totalrank'

    """#
}
