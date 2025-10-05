import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:geolocator/geolocator.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';

void main() {
  runApp(const SpeedometerApp());
}

class SpeedometerApp extends StatelessWidget {
  const SpeedometerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(375, 812), // iPhone X/11 Pro size
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) {
        return MaterialApp(
          title: 'Pro Speedometer',
          theme: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: const Color(0xFF0A0E21),
            primaryColor: const Color(0xFF00D9FF),
          ),
          home: const SpeedometerScreen(),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

enum SpeedUnit { kmh, mph, ms }

class TripData {
  double maxSpeed = 0;
  double totalDistance = 0;
  DateTime? startTime;
  DateTime? endTime;
  List<double> speeds = [];

  double get averageSpeed {
    if (speeds.isEmpty) return 0;
    return speeds.reduce((a, b) => a + b) / speeds.length;
  }

  Duration get duration {
    if (startTime == null) return Duration.zero;
    return (endTime ?? DateTime.now()).difference(startTime!);
  }

  void reset() {
    maxSpeed = 0;
    totalDistance = 0;
    startTime = null;
    endTime = null;
    speeds.clear();
  }
}

class SpeedometerScreen extends StatefulWidget {
  const SpeedometerScreen({super.key});

  @override
  State<SpeedometerScreen> createState() => _SpeedometerScreenState();
}

class _SpeedometerScreenState extends State<SpeedometerScreen>
    with TickerProviderStateMixin {
  double _speed = 0;
  double _altitude = 0;
  double _heading = 0;
  // ignore: unused_field
  Position? _currentPosition;
  Position? _lastPosition;

  SpeedUnit _speedUnit = SpeedUnit.kmh;
  bool _isTracking = false;
  bool _isLoading = true;
  String? _errorMessage;

  TripData _tripData = TripData();
  double _speedLimit = 80; // default speed limit in km/h
  bool _showSpeedWarning = false;

  StreamSubscription<Position>? _positionStream;
  Timer? _durationTimer;
  late AnimationController _pulseController;
  late AnimationController _warningController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _warningController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);

    _checkPermissions();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _durationTimer?.cancel();
    _pulseController.dispose();
    _warningController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _errorMessage = 'Location services are disabled. Please enable GPS.';
          _isLoading = false;
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _errorMessage = 'Location permissions denied.';
            _isLoading = false;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _errorMessage = 'Location permissions permanently denied.';
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = null;
      });

      // _startTracking();
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  void _startTracking() async {
    if (_isTracking) return; // prevent duplicate sessions

    // 🔐 Request permission safely
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      debugPrint('Location permission denied');
      return;
    }

    // 🕒 Initialize trip
    setState(() {
      _isTracking = true;
      _tripData.startTime = DateTime.now();
      _tripData.endTime = null;
    });

    // 🧭 Cancel old stream/timer if still active (safety)
    _positionStream?.cancel();
    _durationTimer?.cancel();

    // ⏱️ Start duration timer
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isTracking) {
        timer.cancel();
        return;
      }
      setState(() {}); // triggers UI time updates
    });

    // 📍 Start location updates
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
          ),
        ).listen((Position position) {
          if (!_isTracking) return; // ignore if stopped
          _updatePosition(position);
        });

    debugPrint('✅ Tracking started at ${_tripData.startTime}');
  }

  void _stopTracking() {
    // 🛑 Stop location & timer
    _positionStream?.cancel();
    _positionStream = null;

    _durationTimer?.cancel();
    _durationTimer = null;

    // 🧭 Mark end of trip
    setState(() {
      _isTracking = false;
      _tripData.endTime = DateTime.now();
      _speed = 0; // reset current speed
    });

    debugPrint('🛑 Tracking stopped at ${_tripData.endTime}');
  }

  void _resetTrip() {
    if (_isTracking) {
      _stopTracking();
    }

    setState(() {
      _tripData.reset();
      _speed = 0;
      _showSpeedWarning = false;
    });
  }

  void _updatePosition(Position position) {
    double speedInMps = position.speed;
    double speedInKmh = speedInMps * 3.6;

    // Filter out negative or unrealistic speeds
    if (speedInKmh < 0) speedInKmh = 0;
    if (speedInKmh > 400) return; // Ignore unrealistic speeds

    // Calculate distance if we have a previous position
    if (_lastPosition != null && speedInKmh > 1) {
      double distance = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      _tripData.totalDistance += distance / 1000; // Convert to km
    }

    setState(() {
      _speed = speedInKmh;
      _altitude = position.altitude;
      _heading = position.heading;
      _currentPosition = position;
      _lastPosition = position;

      // Update trip data
      if (speedInKmh > _tripData.maxSpeed) {
        _tripData.maxSpeed = speedInKmh;
      }

      if (speedInKmh > 1) {
        // Only record meaningful speeds
        _tripData.speeds.add(speedInKmh);
      }

      // Check speed warning
      _showSpeedWarning = speedInKmh > _speedLimit;
      if (_showSpeedWarning) {
        HapticFeedback.mediumImpact();
      }
    });
  }

  double _convertSpeed(double speedKmh) {
    switch (_speedUnit) {
      case SpeedUnit.kmh:
        return speedKmh;
      case SpeedUnit.mph:
        return speedKmh * 0.621371;
      case SpeedUnit.ms:
        return speedKmh / 3.6;
    }
  }

  String _getSpeedUnitLabel() {
    switch (_speedUnit) {
      case SpeedUnit.kmh:
        return 'km/h';
      case SpeedUnit.mph:
        return 'mph';
      case SpeedUnit.ms:
        return 'm/s';
    }
  }

  double _getGaugeMax() {
    switch (_speedUnit) {
      case SpeedUnit.kmh:
        return 240;
      case SpeedUnit.mph:
        return 150;
      case SpeedUnit.ms:
        return 70;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Theme.of(context).primaryColor),
              SizedBox(height: 20.h),
              Text('Initializing GPS...', style: TextStyle(fontSize: 16.sp)),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24.w),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 64.sp, color: Colors.red[400]),
                SizedBox(height: 20.h),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16.sp),
                ),
                SizedBox(height: 20.h),
                ElevatedButton.icon(
                  onPressed: _checkPermissions,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final displaySpeed = _convertSpeed(_speed);
    final maxSpeed = _convertSpeed(_tripData.maxSpeed);
    final avgSpeed = _convertSpeed(_tripData.averageSpeed);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // Animated background gradient
            AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _showSpeedWarning
                      ? [const Color(0xFF0A0E21), const Color(0xFF3D0814)]
                      : [const Color(0xFF0A0E21), const Color(0xFF1D1E33)],
                ),
              ),
            ),

            SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
                child: Column(
                  children: [
                    // Header with unit selector
                    _buildHeader(),

                    SizedBox(height: 10.h),

                    // Main speedometer gauge
                    _buildSpeedGauge(displaySpeed),

                    SizedBox(height: 10.h),

                    // Compass and altitude
                    // _buildCompassAltitude(),
                    SizedBox(height: 10.h),

                    // Trip statistics
                    _buildTripStats(maxSpeed, avgSpeed),

                    SizedBox(height: 10.h),

                    // Control buttons
                    // _buildControlButtons(),
                  ],
                ),
              ),
            ),

            Positioned(
              left: 16.w,
              right: 16.w,
              bottom: MediaQuery.of(context).padding.bottom + 16,
              child: _buildControlButtons(),
            ),

            // Speed warning overlay
            if (_showSpeedWarning)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: FadeTransition(
                  opacity: _warningController,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.red.withOpacity(0.3),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.warning, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          'SPEED LIMIT EXCEEDED',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 40.h,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              'SPEEDOMETER',
              style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20.r),
            ),
            child: Row(
              children: [
                _buildUnitButton(SpeedUnit.kmh, 'km/h'),
                _buildUnitButton(SpeedUnit.mph, 'mph'),
                _buildUnitButton(SpeedUnit.ms, 'm/s'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnitButton(SpeedUnit unit, String label) {
    final isSelected = _speedUnit == unit;
    return GestureDetector(
      onTap: () => setState(() => _speedUnit = unit),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).primaryColor
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20.r),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.sp,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedGauge(double displaySpeed) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: _showSpeedWarning
                ? Colors.red.withOpacity(0.3)
                : Theme.of(context).primaryColor.withOpacity(0.2),
            blurRadius: 30.r,
            spreadRadius: 5.r,
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          double gaugeSize = math.min(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          return SizedBox(
            height: gaugeSize,
            width: gaugeSize,
            child: SfRadialGauge(
              axes: <RadialAxis>[
                RadialAxis(
                  minimum: 0,
                  maximum: _getGaugeMax(),
                  interval: _speedUnit == SpeedUnit.ms ? 10 : 20,
                  axisLineStyle: const AxisLineStyle(
                    thickness: 0.15,
                    thicknessUnit: GaugeSizeUnit.factor,
                    color: Color(0xFF1D1E33),
                  ),
                  majorTickStyle: const MajorTickStyle(
                    length: 0.15,
                    lengthUnit: GaugeSizeUnit.factor,
                    thickness: 2,
                    color: Colors.white30,
                  ),
                  minorTickStyle: const MinorTickStyle(
                    length: 0.05,
                    lengthUnit: GaugeSizeUnit.factor,
                    thickness: 1.5,
                    color: Colors.white10,
                  ),
                  axisLabelStyle: GaugeTextStyle(
                    color: Colors.white54,
                    fontSize: 10.sp,
                  ),
                  ranges: <GaugeRange>[
                    GaugeRange(
                      startValue: 0,
                      endValue: _getGaugeMax() * 0.4,
                      color: Colors.green,
                      startWidth: 15,
                      endWidth: 25,
                    ),
                    GaugeRange(
                      startValue: _getGaugeMax() * 0.4,
                      endValue: _getGaugeMax() * 0.7,
                      color: Colors.orange,
                      startWidth: 25,
                      endWidth: 25,
                    ),
                    GaugeRange(
                      startValue: _getGaugeMax() * 0.7,
                      endValue: _getGaugeMax(),
                      color: Colors.red,
                      startWidth: 25,
                      endWidth: 15,
                    ),
                  ],
                  pointers: <GaugePointer>[
                    NeedlePointer(
                      value: displaySpeed,
                      needleLength: 0.7,
                      lengthUnit: GaugeSizeUnit.factor,
                      needleStartWidth: 1,
                      needleEndWidth: 5,
                      knobStyle: KnobStyle(
                        knobRadius: 0.08,
                        sizeUnit: GaugeSizeUnit.factor,
                        color: Theme.of(context).primaryColor,
                        borderColor: Colors.white,
                        borderWidth: 0.02,
                      ),
                      needleColor: Theme.of(context).primaryColor,
                      enableAnimation: true,
                      animationDuration: 500,
                      animationType: AnimationType.ease,
                    ),
                  ],
                  annotations: <GaugeAnnotation>[
                    GaugeAnnotation(
                      widget: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displaySpeed.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 42.sp,
                              fontWeight: FontWeight.bold,
                              color: _showSpeedWarning
                                  ? Colors.red
                                  : Theme.of(context).primaryColor,
                              shadows: [
                                Shadow(
                                  color: _showSpeedWarning
                                      ? Colors.red
                                      : Theme.of(context).primaryColor,
                                  blurRadius: 20,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            _getSpeedUnitLabel(),
                            style: TextStyle(
                              fontSize: 14.sp,
                              color: Colors.white54,
                              letterSpacing: 2,
                            ),
                          ),
                        ],
                      ),
                      angle: 90,
                      positionFactor: 0.6,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ignore: unused_element
  Widget _buildCompassAltitude() {
    return Row(
      children: [
        Expanded(
          child: _buildInfoCard(
            icon: Icons.navigation,
            label: 'Heading',
            value: '${_heading.toStringAsFixed(0)}°',
            rotation: _heading * math.pi / 180,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildInfoCard(
            icon: Icons.terrain,
            label: 'Altitude',
            value: '${_altitude.toStringAsFixed(0)} m',
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String label,
    required String value,
    double? rotation,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
      ),
      child: Column(
        children: [
          Transform.rotate(
            angle: rotation ?? 0,
            child: Icon(icon, color: Theme.of(context).primaryColor, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTripStats(double maxSpeed, double avgSpeed) {
    return Builder(
      builder: (context) {
        return Container(
          padding: EdgeInsets.all(20.w),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(
              color: Colors.white.withOpacity(0.1),
              width: 1.w,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'TRIP STATISTICS',
                    style: TextStyle(
                      fontSize: 14.sp,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5.w,
                      color: Colors.white54,
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 8.w,
                      vertical: 4.h,
                    ),
                    decoration: BoxDecoration(
                      color: _isTracking ? Colors.green : Colors.red,
                      borderRadius: BorderRadius.circular(12.r),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8.w,
                          height: 8.w,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                        SizedBox(width: 6.w),
                        Text(
                          _isTracking ? 'TRACKING' : 'STOPPED',
                          style: TextStyle(
                            fontSize: 10.sp,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 20.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildStatItem(
                    context,
                    'Max Speed',
                    '${maxSpeed.toStringAsFixed(1)}',
                    _getSpeedUnitLabel(),
                  ),
                  _buildStatItem(
                    context,
                    'Avg Speed',
                    '${avgSpeed.toStringAsFixed(1)}',
                    _getSpeedUnitLabel(),
                    alignEnd: true,
                  ),
                ],
              ),
              SizedBox(height: 16.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildStatItem(
                    context,
                    'Distance',
                    '${_tripData.totalDistance.toStringAsFixed(2)}',
                    'km',
                  ),
                  _buildStatItem(
                    context,
                    'Duration',
                    _formatDuration(_tripData.duration),
                    '',
                    alignEnd: true, // 👈 make only this one right-aligned
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatItem(
    BuildContext context,
    String label,
    String value,
    String unit, {
    bool alignEnd = false, // default left-aligned
  }) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          textAlign: alignEnd ? TextAlign.end : TextAlign.start,
          style: TextStyle(color: Colors.white54, fontSize: 12.sp),
        ),
        SizedBox(height: 4.h),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              value,
              style: TextStyle(
                color: Theme.of(context).primaryColor,
                fontSize: 24.sp,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (unit.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(left: 4.w, bottom: 2.h),
                child: Text(
                  unit,
                  style: TextStyle(color: Colors.white54, fontSize: 14.sp),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildControlButtons() {
    return Container(
      height: 56.h, // slightly taller for better touch target
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: ElevatedButton.icon(
              onPressed: _isTracking ? _stopTracking : _startTracking,
              icon: Icon(
                _isTracking ? Icons.stop : Icons.play_arrow,
                size: 24.sp, // bigger icon
              ),
              label: Text(
                _isTracking ? 'Stop Trip' : 'Start Trip',
                style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isTracking ? Colors.red : Colors.green,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(vertical: 14.h),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.r),
                ),
              ),
            ),
          ),
          SizedBox(width: 16.w), // more spacing
          Expanded(
            flex: 1,
            child: ElevatedButton(
              onPressed: _resetTrip,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.15),
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(vertical: 14.h),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.r),
                ),
              ),
              child: Icon(Icons.refresh, size: 24.sp), // bigger icon
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String hours = twoDigits(duration.inHours);
    String minutes = twoDigits(duration.inMinutes.remainder(60));
    String seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }
}
