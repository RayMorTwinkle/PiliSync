import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/search_panel/controller.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/url_utils.dart';
import 'package:PiliPlus/models/search/search_esports.dart';
import 'package:PiliPlus/pages/search_panel/video/controller.dart';

class SearchAllController extends SearchVideoController with SearchVideoMixin {
  SearchAllController({
    required super.keyword,
    required super.searchType,
    required super.tag,
  });

  List<SearchUser>? searchUser;
  List<SearchPgcItemModel>? searchMedia;
  List<SearchActivity>? searchActivity;
  SearchEsports? searchEsports;

  @override
  bool customHandleResponse(bool isRefresh, Success<SearchVideoData> response) {
    final res = response.response;
    if (isRefresh) {
      searchType_ = .video;
      searchUser = res.searchUser;
      searchMedia = res.searchMedia;
      searchActivity = res.searchActivity;
      searchEsports = res.searchEsports;
    }
    return super.customHandleResponse(isRefresh, response);
  }

  @override
  late var searchType_ = searchType;

  void _computeActualSearchType() {
    if (order.isNotEmpty ||
        videoDurationType != .all ||
        videoZoneType != .all ||
        pubBegin != null ||
        pubEnd != null) {
      searchType_ = .video;
      return;
    }
    searchType_ = .all;
  }

  @override
  Future<void> onRefresh() {
    _computeActualSearchType();
    searchUser = null;
    searchMedia = null;
    searchActivity = null;
    searchEsports = null;
    return super.onRefresh();

  static final _b23Regex = RegExp(r'b23\.tv/[A-Za-z0-9]{7}$', caseSensitive: false);

  Future<void> jump2Video() async {
    if (IdUtils.avRegexExact.hasMatch(keyword)) {
      hasJump2Video = true;
      PiliScheme.videoPush(
        int.parse(keyword.substring(2)),
        null,
        showDialog: false,
      );
    } else if (IdUtils.bvRegexExact.hasMatch(keyword)) {
      hasJump2Video = true;
      PiliScheme.videoPush(null, keyword, showDialog: false);
    } else if (_b23Regex.hasMatch(keyword)) {
      hasJump2Video = true;
      final redirectUrl = await UrlUtils.parseRedirectUrl(keyword);
      if (redirectUrl != null) {
        final matchRes = IdUtils.matchAvorBv(input: redirectUrl);
        final aid = matchRes.av;
        String? bvid = matchRes.bv;
        if (aid != null || bvid != null) {
          bvid ??= IdUtils.av2bv(aid!);
          PiliScheme.videoPush(aid, bvid, showDialog: false);
        }
      }
    }
  }
}
