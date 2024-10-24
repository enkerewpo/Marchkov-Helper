import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/reservation_provider.dart';
import '../../models/reservation.dart';
import '../../services/reservation_service.dart';
import '../../services/auth_service.dart'; // 新增导入
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../../providers/auth_provider.dart';
import '../../services/ride_history_service.dart';
import 'package:intl/intl.dart';

// 导入新的组件
import 'ride_card.dart';

class RidePage extends StatefulWidget {
  const RidePage({super.key});

  @override
  RidePageState createState() => RidePageState();
}

class RidePageState extends State<RidePage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late Future<bool> _cookieValidationFuture;

  bool _isToggleLoading = false;

  bool _isGoingToYanyuan = true;

  List<Map<String, dynamic>> _nearbyBuses = [];
  int _selectedBusIndex = -1;

  // 添加预约相关变量

  // 添加 PageController 属性
  late PageController _pageController;

  // 添加一个加载状��变量
  bool _isLoading = true;

  // 添加新的属性
  bool? _showTip1;
  bool? _showTip2;

  // 添加一个新的列来存储每个卡片的状态
  List<Map<String, dynamic>> _cardStates = [];

  bool _showSlowLoadingTip = false;

  @override
  void initState() {
    super.initState();
    _cookieValidationFuture = _validateCookies();
    _initialize();
    _loadTipPreference();

    // 初始化 PageController，设置初始页面和视口Fraction
    _pageController = PageController(
      initialPage: 0,
      viewportFraction: 0.9, // 调整视口Fraction，使卡片占据更大的宽度
    );
    _startSlowLoadingTimer();
  }

  void _startSlowLoadingTimer() {
    Future.delayed(Duration(milliseconds: 1500), () {
      if (mounted && _isLoading) {
        setState(() {
          _showSlowLoadingTip = true;
        });
      }
    });
  }

  @override
  void dispose() {
    // 释放 PageController 资源
    _pageController.dispose();
    super.dispose();
  }

  Future<bool> _validateCookies() async {
    final authService = AuthService();
    print('开始验证 cookies...');
    bool isValid = await authService.validateAndRefreshLoginStatus();
    print('Cookies 验证结果: ${isValid ? "有效" : "无效"}');
    return isValid;
  }

  // 修改 _initialize 方法以并行获取所有班车的数据
  Future<void> _initialize() async {
    await _loadNearbyBuses();

    if (!mounted) return; // 检查组件是否仍然在树中

    if (_nearbyBuses.isNotEmpty) {
      setState(() {
        _selectedBusIndex = 0;
        // 初始化每个卡片的状态
        _cardStates = List.generate(
            _nearbyBuses.length,
            (index) => {
                  'qrCode': null,
                  'departureTime': '',
                  'routeName': '',
                  'codeType': '',
                  'errorMessage': '',
                });
      });
      // 并行获取所有班车的二维码
      await Future.wait([
        for (int i = 0; i < _nearbyBuses.length; i++)
          _fetchBusData(i), // 新增方法，用于获取每个班车的���据
      ]);
    } else {
      setState(() {});
    }

    // 数据加载完成，更新加载状态
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 新增方法，用于并行获取每个班车的数据而不改变选中的班车索引
  Future<void> _fetchBusData(int index) async {
    final bus = _nearbyBuses[index];
    final reservationProvider =
        Provider.of<ReservationProvider>(context, listen: false);
    final reservationService =
        ReservationService(Provider.of<AuthProvider>(context, listen: false));

    try {
      await reservationProvider.loadCurrentReservations();
      Reservation? matchingReservation;

      try {
        matchingReservation =
            reservationProvider.currentReservations.firstWhere(
          (reservation) =>
              reservation.resourceName == bus['route_name'] &&
              reservation.appointmentTime ==
                  '${bus['abscissa']} ${bus['yaxis']}',
        );
      } catch (e) {
        matchingReservation = null; // 如果没有找到匹配的预约，设置为 null
      }

      if (matchingReservation != null) {
        await _fetchQRCode(reservationProvider, matchingReservation, index);
      } else {
        // 仅比较 HH:mm
        final departureTimeStr = bus['yaxis']; // "HH:mm"
        final nowStr = DateFormat('HH:mm').format(DateTime.now());
        final isPastDeparture = departureTimeStr.compareTo(nowStr) <= 0;

        if (isPastDeparture) {
          final tempCode = await _fetchTempCode(reservationService, bus);
          if (tempCode != null) {
            if (mounted) {
              setState(() {
                _cardStates[index] = {
                  'qrCode': tempCode['code'],
                  'departureTime': tempCode['departureTime']!,
                  'routeName': bus['route_name'],
                  'codeType': '临时码',
                  'errorMessage': '',
                };
              });
            }
          } else {
            if (mounted) {
              setState(() {
                _cardStates[index]['errorMessage'] = '无法获取临时码';
              });
            }
          }
        } else {
          if (mounted) {
            setState(() {
              _cardStates[index] = {
                'qrCode': null,
                'departureTime': bus['yaxis'],
                'routeName': bus['route_name'],
                'codeType': '待预约',
                'errorMessage': '',
              };
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cardStates[index]['errorMessage'] = '加载数据时出错: $e';
        });
      }
    }
  }

  Future<void> _loadNearbyBuses() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final todayString = now.toIso8601String().split('T')[0];

    // 尝试从缓存中读取数据
    final cachedBusDataString = prefs.getString('cachedBusData');
    // print('cachedBusDataString: $cachedBusDataString');
    final cachedDate = prefs.getString('cachedDate');

    if (cachedBusDataString != null && cachedDate == todayString) {
      // 如果有当天的缓存数据，直接使用
      final cachedBusData = json.decode(cachedBusDataString);
      _processBusData(cachedBusData);
    } else {
      // 如果没有缓存或缓存不是当天的，重新获取数据
      if (!mounted) return; // 添加这行来检查组件是否仍然挂载
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final reservationService = ReservationService(authProvider);

      try {
        final allBuses = await reservationService.getAllBuses([todayString]);

        // 缓存新获取的数据
        await prefs.setString('cachedBusData', json.encode(allBuses));
        await prefs.setString('cachedDate', todayString);

        if (!mounted) return; // 再次检查组件是否仍然挂载
        _processBusData(allBuses);
      } catch (e) {
        print('加载附近班车失败: $e');
      }
    }

    // 新增: 获取乘车历史并统计乘坐次数
    if (mounted) {
      // 添加这行来检查组件是否仍然挂载
      await _loadRideHistory();
    }
  }

  void _processBusData(List<dynamic> busData) {
    final now = DateTime.now();
    _nearbyBuses = busData
        .where((bus) {
          final busTime = DateTime.parse('${bus['abscissa']} ${bus['yaxis']}');
          final diff = busTime.difference(now).inMinutes;

          // 添加路线名称过滤条件
          final routeName = bus['route_name'].toString().toLowerCase();
          final containsXin = routeName.contains('新');
          final containsYan = routeName.contains('燕');

          return diff >= -30 && diff <= 30 && containsXin && containsYan;
        })
        .toList()
        .cast<Map<String, dynamic>>();

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadRideHistory() async {
    final rideHistoryService =
        RideHistoryService(Provider.of<AuthProvider>(context, listen: false));
    final rideHistory = await rideHistoryService.getRideHistory();

    // 统计每个班车（路线名 + 时间，不含日期）的乘坐次数
    Map<String, int> busUsageCount = {};
    for (var bus in _nearbyBuses) {
      String busKey = '${bus['route_name']}_${bus['yaxis']}'; // 只使用时间，不包含日期
      busUsageCount[busKey] = 0;
    }

    for (var ride in rideHistory) {
      DateTime rideDateTime = DateTime.parse(ride.appointmentTime);
      String rideTime = DateFormat('HH:mm').format(rideDateTime);
      String rideKey = '${ride.resourceName}_$rideTime';
      if (busUsageCount.containsKey(rideKey)) {
        busUsageCount[rideKey] = busUsageCount[rideKey]! + 1;
      }
    }

    // 根据乘坐次数对班车进行排序
    _nearbyBuses.sort((a, b) {
      String keyA = '${a['route_name']}_${a['yaxis']}';
      String keyB = '${b['route_name']}_${b['yaxis']}';
      return busUsageCount[keyB]!.compareTo(busUsageCount[keyA]!);
    });

    // 打印每个班车的乘坐次数
    for (var bus in _nearbyBuses) {
      String busKey = '${bus['route_name']}_${bus['yaxis']}';
      print('班车: $busKey, 乘坐次数: ${busUsageCount[busKey]}');
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _selectBus(int index) async {
    if (!mounted) return; // 检查组件是否仍然在树中

    setState(() {
      _selectedBusIndex = index;
    });

    // 修改下条件：基于 'codeType' 而不是 'errorMessage'
    if (_cardStates[index]['codeType'] == '乘车码') {
      return; // 如果已经是乘车码，不需要重新获取数据
    }

    final bus = _nearbyBuses[index];
    final reservationProvider =
        Provider.of<ReservationProvider>(context, listen: false);
    final reservationService =
        ReservationService(Provider.of<AuthProvider>(context, listen: false));

    try {
      await reservationProvider.loadCurrentReservations();
      Reservation? matchingReservation;

      try {
        matchingReservation =
            reservationProvider.currentReservations.firstWhere(
          (reservation) =>
              reservation.resourceName == bus['route_name'] &&
              reservation.appointmentTime ==
                  '${bus['abscissa']} ${bus['yaxis']}',
        );
      } catch (e) {
        matchingReservation = null; // 如果没有找到匹配的预约，设置为 null
      }

      if (matchingReservation != null) {
        await _fetchQRCode(reservationProvider, matchingReservation, index);
      } else {
        // 仅比较 HH:mm
        final departureTimeStr = bus['yaxis']; // "HH:mm"
        final nowStr = DateFormat('HH:mm').format(DateTime.now());
        final isPastDeparture = departureTimeStr.compareTo(nowStr) <= 0;

        if (isPastDeparture) {
          final tempCode = await _fetchTempCode(reservationService, bus);
          if (tempCode != null) {
            if (mounted) {
              setState(() {
                _cardStates[index] = {
                  'qrCode': tempCode['code'],
                  'departureTime': tempCode['departureTime']!,
                  'routeName': bus['route_name'],
                  'codeType': '临时码',
                  'errorMessage': '',
                };
              });
            }
          } else {
            if (mounted) {
              setState(() {
                _cardStates[index]['errorMessage'] = '无法获取临时码';
              });
            }
          }
        } else {
          if (mounted) {
            setState(() {
              _cardStates[index] = {
                'qrCode': null,
                'departureTime': bus['yaxis'],
                'routeName': bus['route_name'],
                'codeType': '待预约',
                'errorMessage': '',
              };
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cardStates[index]['errorMessage'] = '加载数据时出错: $e';
        });
      }
    }
  }

  Future<void> _fetchQRCode(
      ReservationProvider provider, Reservation reservation, int index) async {
    try {
      await provider.fetchQRCode(
        reservation.id.toString(),
        reservation.hallAppointmentDataId.toString(),
      );

      final actualDepartureTime = await _getActualDepartureTime(reservation);

      if (mounted) {
        setState(() {
          _cardStates[index] = {
            'qrCode': provider.qrCode,
            'departureTime': actualDepartureTime,
            'routeName': reservation.resourceName,
            'codeType': '乘车码',
            'appointmentId': reservation.id.toString(),
            'hallAppointmentDataId':
                reservation.hallAppointmentDataId.toString(),
            'errorMessage': '',
          };
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cardStates[index]['errorMessage'] = '获取二维码时出错: $e';
        });
      }
    }
  }

  Future<String> _getActualDepartureTime(Reservation reservation) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedBusDataString = prefs.getString('cachedBusData');
    if (cachedBusDataString != null) {
      final buses = jsonDecode(cachedBusDataString);
      final matchingBus = buses.firstWhere(
        (bus) =>
            bus['route_name'] == reservation.resourceName &&
            '${bus['abscissa']} ${bus['yaxis']}' == reservation.appointmentTime,
        orElse: () => null,
      );
      if (matchingBus != null) {
        return matchingBus['yaxis'];
      }
    }
    return reservation.appointmentTime.split(' ')[1];
  }

  Future<Map<String, String>?> _fetchTempCode(
      ReservationService service, Map<String, dynamic> bus) async {
    final resourceId = bus['bus_id'].toString();
    final startTime = '${bus['abscissa']} ${bus['yaxis']}';
    final code = await service.getTempQRCode(resourceId, startTime);
    return {
      'code': code,
      'departureTime': bus['yaxis'],
      'routeName': bus['route_name'],
    };
  }

  // 修改 _loadTipPreference 方法以加载两个提示的状态
  Future<void> _loadTipPreference() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showTip1 = prefs.getBool('showRideTip1') ?? true;
      _showTip2 = prefs.getBool('showRideTip2') ?? true;
    });
  }

  // 修改 _saveTipPreference 方法以保存两个提示的状态
  Future<void> _saveTipPreference(bool showTip1, bool showTip2) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showRideTip1', showTip1);
    await prefs.setBool('showRideTip2', showTip2);
  }

  // 新增方法用于显示第一个提示对话框
  void _showTipDialog1() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('乘车提示'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1. 本页面只会显示过去30分钟到未来30分钟内发车的班车。'),
            Text('2. 如果已错过发车时刻，将无法预约，只会显示乘车码或临时码。'),
            Text('3. 应用会学习您的乘车偏好，根据历史乘车记录智能推荐班车。目前需要您手动打开设置-乘车历史，以缓存乘车记录。'),
            Text('4. 如果加载太慢，尝试关闭代理。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                _showTip1 = false;
              });
              _saveTipPreference(false, _showTip2 ?? true);
            },
            child: Text('不再显示'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('确定'),
          ),
        ],
      ),
    );
  }

  // 新增方法用于显示第二个提示对话框
  void _showTipDialog2() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('二维码可以点击！'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1. 点击二维码可以切换到仿官方页面。'),
            Text('2. 主页面和仿官方页面的二维码都是有效的。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                _showTip2 = false;
              });
              _saveTipPreference(_showTip1 ?? true, false);
            },
            child: Text('不再显示'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelReservation(int index) async {
    final cardState = _cardStates[index];
    if (cardState['appointmentId'] == null ||
        cardState['hallAppointmentDataId'] == null) {
      setState(() {
        cardState['errorMessage'] = '无有效的预约信息';
      });
      return;
    }

    setState(() {
      _isToggleLoading = true;
      cardState['errorMessage'] = '';
    });

    final reservationService =
        ReservationService(Provider.of<AuthProvider>(context, listen: false));

    try {
      await reservationService.cancelReservation(
        cardState['appointmentId'],
        cardState['hallAppointmentDataId'],
      );

      // 仅比较 HH:mm
      final bus = _nearbyBuses[index];
      final departureTimeStr = bus['yaxis']; // "HH:mm"
      final nowStr = DateFormat('HH:mm').format(DateTime.now());
      final isPastDeparture = departureTimeStr.compareTo(nowStr) <= 0;

      if (isPastDeparture) {
        final tempCode = await _fetchTempCode(reservationService, bus);
        if (tempCode != null) {
          if (mounted) {
            setState(() {
              _cardStates[index] = {
                'qrCode': tempCode['code'],
                'departureTime': tempCode['departureTime']!,
                'routeName': bus['route_name'],
                'codeType': '临时码',
                'errorMessage': '',
              };
            });
          }
        } else {
          if (mounted) {
            setState(() {
              cardState['errorMessage'] = '无法获取临时码';
            });
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _cardStates[index] = {
              'qrCode': null,
              'departureTime': bus['yaxis'],
              'routeName': bus['route_name'],
              'codeType': '待预约',
              'errorMessage': '',
            };
          });
        }
      }
    } catch (e) {
      setState(() {
        cardState['errorMessage'] = '取消预约失败: $e';
      });
    } finally {
      setState(() {
        _isToggleLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return FutureBuilder<bool>(
      future: _cookieValidationFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting || _isLoading) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  if (_showSlowLoadingTip)
                    Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: Text(
                        '加载缓慢，尝试关闭代理、连接校园网或退出登录重进',
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          );
        } else if (snapshot.hasError || snapshot.data == false) {
          return Scaffold(
            body: Center(
              child: Text('登录状态验证失败，请重新登录'),
            ),
          );
        } else {
          return _buildMainContent();
        }
      },
    );
  }

  Widget _buildMainContent() {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final secondaryColor = theme.colorScheme.secondary;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  kToolbarHeight,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 修改乘车提示部分，添加新的二维码提示
                if (_showTip1 == true || _showTip2 == true)
                  Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                    child: Row(
                      children: [
                        if (_showTip1 == true)
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _showTipDialog1,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                padding: EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 0), // 减小水平内边距
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.info_outline,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      size: 16),
                                  SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      '查看乘车提示',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.color,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                      overflow:
                                          TextOverflow.ellipsis, // 文本溢出时显示省略号
                                      maxLines: 1, // 限制为单行
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (_showTip1 == true && _showTip2 == true)
                          SizedBox(width: 8),
                        if (_showTip2 == true)
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _showTipDialog2,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                padding: EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 0), // 减小水平内边距
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.qr_code,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      size: 16),
                                  SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      '二维码可以点击！',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.color,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                      overflow:
                                          TextOverflow.ellipsis, // 文本溢出时显示省略号
                                      maxLines: 1, // 限制为单行
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                SizedBox(
                  height: 600,
                  child: _nearbyBuses.isEmpty
                      ? Center(child: Text('无车可坐'))
                      : PageView.builder(
                          controller: _pageController,
                          itemCount: _nearbyBuses.length,
                          onPageChanged: (index) {
                            _selectBus(index);
                          },
                          itemBuilder: (context, index) {
                            return RideCard(
                              cardState: _cardStates[index],
                              isGoingToYanyuan: _isGoingToYanyuan,
                              onMakeReservation: () => _makeReservation(index),
                              onCancelReservation: () =>
                                  _cancelReservation(index),
                              isToggleLoading: _isToggleLoading,
                            );
                          },
                        ),
                ),
                SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _nearbyBuses.length,
                      (index) => Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4.0),
                        width: 8.0,
                        height: 8.0,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _selectedBusIndex == index
                              ? primaryColor
                              : secondaryColor.withOpacity(0.3),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _makeReservation(int index) async {
    setState(() {
      _isToggleLoading = true;
      _cardStates[index]['errorMessage'] = '';
    });

    final bus = _nearbyBuses[index];
    final reservationService =
        ReservationService(Provider.of<AuthProvider>(context, listen: false));
    final reservationProvider =
        Provider.of<ReservationProvider>(context, listen: false);

    try {
      await reservationService.makeReservation(
        bus['bus_id'].toString(),
        bus['abscissa'],
        bus['time_id'].toString(),
      );

      // 获取最新的预约列表
      await reservationProvider.loadCurrentReservations();

      // 尝试匹配刚刚预约的班车
      Reservation? matchingReservation;
      try {
        matchingReservation =
            reservationProvider.currentReservations.firstWhere(
          (reservation) =>
              reservation.resourceName == bus['route_name'] &&
              reservation.appointmentTime ==
                  '${bus['abscissa']} ${bus['yaxis']}',
        );
      } catch (e) {
        matchingReservation = null;
      }

      if (matchingReservation != null) {
        // 获取乘车码
        await _fetchQRCode(reservationProvider, matchingReservation, index);
      } else {
        setState(() {
          _cardStates[index]['errorMessage'] = '无法找到匹配的预约信息';
        });
      }
    } catch (e) {
      setState(() {
        _cardStates[index]['errorMessage'] = '预约失败: $e';
      });
    } finally {
      setState(() {
        _isToggleLoading = false;
      });
    }
  }
}
