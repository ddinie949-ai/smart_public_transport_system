import 'dart:async';

import 'package:flutter/material.dart';

import '../data/geocoding_service.dart';
import '../data/input_validator.dart';
import '../data/journey_notification_service.dart';
import '../data/local_storage_service.dart';
import '../data/location_service.dart';
import '../data/malaysia_time.dart';
import '../data/transit_repository.dart';
import '../models/transit_models.dart';
import '../theme/app_theme.dart';
import 'journey_planner_screen.dart';
import 'profile_screen.dart';
import 'supported_stop_map_picker.dart';
import 'transit_map_screen.dart';
import 'travel_history_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}
//test
class _DashboardScreenState extends State<DashboardScreen> {
  final LocalStorageService _storage = LocalStorageService.instance;
  final TransitRepository _repository = TransitRepository.instance;
  final LocationService _locationService = LocationService();
  final GeocodingService _geocodingService = GeocodingService();
  final JourneyNotificationService _notifications =
      JourneyNotificationService.instance;

  final TextEditingController _originController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();
  JourneyLocation? _originLocation;
  JourneyLocation? _destinationLocation;

  int _selectedIndex = 0;
  bool _isLoading = true;
  bool _gettingLocation = false;
  bool _choosingLocation = false;
  bool _dashboardRequestInFlight = false;
  bool _handlingNotificationJourney = false;
  Timer? _clockTimer;
  final Set<String> _automaticallyOpenedJourneyIds = <String>{};
  Key _plannerKey = UniqueKey();
  String? _selectedCategoryId;
  JourneyOption? _activeJourney;
  TransitRoute? _mapRoute;
  SavedJourney? _autoStartSavedJourney;
  SavedJourney? _activeSavedJourney;
  Set<String> _endedJourneyRunKeys = <String>{};
  Key _mapKey = UniqueKey();

  List<FavouriteCategory> _categories = [];
  List<FavouriteItem> _favourites = [];
  List<RecentSearch> _recentSearches = [];
  List<SavedJourney> _savedJourneys = [];
  List<ServiceUsage> _frequentServices = [];

  static const List<String> _pageTitles = [
    'Home',
    'Plan Journey',
    'Transit Map',
    'Travel History',
    'Profile & Settings',
  ];

  @override
  void initState() {
    super.initState();
    _notifications.selectedJourneyId.addListener(
      _onNotificationJourneySelected,
    );
    unawaited(_initialiseNotificationNavigation());
    _fetchDashboardData();
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      _updateJourneyClock();
    });
  }

  @override
  void dispose() {
    _notifications.selectedJourneyId.removeListener(
      _onNotificationJourneySelected,
    );
    _clockTimer?.cancel();
    _originController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  Future<void> _initialiseNotificationNavigation() async {
    await _notifications.initialise();
    if (mounted) _onNotificationJourneySelected();
  }

  void _onNotificationJourneySelected() {
    unawaited(_openNotificationJourney());
  }

  Future<void> _openNotificationJourney() async {
    final journeyId = _notifications.selectedJourneyId.value;
    if (journeyId == null || _handlingNotificationJourney) return;

    _handlingNotificationJourney = true;
    try {
      final journeys = await _storage.getSavedJourneys();
      if (!mounted) return;
      final matching = journeys.where((item) => item.id == journeyId);
      _notifications.clearSelectedJourney(journeyId);
      if (matching.isEmpty) {
        _showMessage('This saved journey is no longer available.');
        return;
      }
      _startSavedJourney(matching.first);
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to open this journey. Please try again.');
      }
    } finally {
      _handlingNotificationJourney = false;
    }
  }

  Future<void> _fetchDashboardData() async {
    if (_dashboardRequestInFlight) return;
    _dashboardRequestInFlight = true;
    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      await _storage.initialise();

      final results = await Future.wait<Object>([
        _storage.getFavouriteCategories(),
        _storage.getFavourites(),
        _storage.getRecentSearches(),
        _storage.getSavedJourneys(),
        _storage.getFrequentServices(),
        _storage.getEndedJourneyRunKeys(),
      ]);
      final categories = results[0] as List<FavouriteCategory>;
      final favourites = results[1] as List<FavouriteItem>;
      final recentSearches = results[2] as List<RecentSearch>;
      final savedJourneys = results[3] as List<SavedJourney>;
      final frequentServices = results[4] as List<ServiceUsage>;
      final endedJourneyRunKeys = results[5] as Set<String>;

      if (!mounted) return;
      setState(() {
        _categories = categories;
        _favourites = favourites;
        _recentSearches = recentSearches;
        _savedJourneys = savedJourneys;
        _frequentServices = frequentServices;
        _endedJourneyRunKeys = endedJourneyRunKeys;
        _isLoading = false;
      });
      _startDueJourneyIfNeeded();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      _showMessage('Unable to load your saved information. Please try again.');
    } finally {
      _dashboardRequestInFlight = false;
    }
  }

  void _startDueJourneyIfNeeded() {
    if (_activeJourney != null || _savedJourneys.isEmpty) return;
    final now = MalaysiaTime.now();
    final due =
        _savedJourneys.where((journey) {
          if (_automaticallyOpenedJourneyIds.contains(journey.id) ||
              _endedJourneyRunKeys.contains(
                LocalStorageService.journeyRunKey(
                  journey.id,
                  journey.departureTime,
                ),
              ) ||
              journey.departureTime.isAfter(now)) {
            return false;
          }
          final visibleMinutes = journey.durationMinutes < 15
              ? 15
              : journey.durationMinutes;
          return now.isBefore(
            journey.departureTime.add(Duration(minutes: visibleMinutes)),
          );
        }).toList()..sort(
          (first, second) =>
              second.departureTime.compareTo(first.departureTime),
        );
    if (due.isEmpty) return;
    _automaticallyOpenedJourneyIds.add(due.first.id);
    _startSavedJourney(due.first);
  }

  void _updateJourneyClock() {
    final activeJourney = _activeJourney;
    if (activeJourney != null &&
        !MalaysiaTime.now().isBefore(activeJourney.arrivalTime)) {
      _clearActiveJourney();
      return;
    }
    setState(() {});
    _startDueJourneyIfNeeded();
  }

  void _changePage(int index) {
    setState(() {
      _selectedIndex = index;
    });
    if (index == 0) {
      _fetchDashboardData();
    }
  }

  void _openPlanner({
    String? origin,
    String? destination,
    JourneyLocation? originLocation,
    JourneyLocation? destinationLocation,
  }) {
    setState(() {
      if (originLocation != null) {
        _originLocation = originLocation;
        _originController.text = originLocation.name;
      } else if (origin != null && origin.isNotEmpty) {
        final stop = _repository.findStop(origin);
        _originLocation = stop == null ? null : JourneyLocation.fromStop(stop);
        _originController.text = origin;
      }
      if (destinationLocation != null) {
        _destinationLocation = destinationLocation;
        _destinationController.text = destinationLocation.name;
      } else if (destination != null) {
        final stop = _repository.findStop(destination);
        _destinationLocation = stop == null
            ? null
            : JourneyLocation.fromStop(stop);
        _destinationController.text = destination;
      }
      _plannerKey = UniqueKey();
      _selectedIndex = 1;
    });
  }

  void _swapLocations() {
    final origin = _originController.text;
    final originLocation = _originLocation;
    setState(() {
      _originController.text = _destinationController.text;
      _destinationController.text = origin;
      _originLocation = _destinationLocation;
      _destinationLocation = originLocation;
    });
  }

  Future<void> _selectLocationFromMap({
    required TextEditingController controller,
    required String title,
    required bool isOrigin,
  }) async {
    if (_choosingLocation) return;
    _choosingLocation = true;
    try {
      final selectedLocation = await Navigator.push<JourneyLocation>(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => SupportedStopMapPicker(
            title: title,
            stops: _repository.stops,
            initialLocation: isOrigin ? _originLocation : _destinationLocation,
          ),
        ),
      );

      if (selectedLocation == null || !mounted) return;
      setState(() {
        controller.text = selectedLocation.name;
        if (isOrigin) {
          _originLocation = selectedLocation;
        } else {
          _destinationLocation = selectedLocation;
        }
      });
    } finally {
      _choosingLocation = false;
    }
  }

  Future<void> _useGpsForOrigin() async {
    if (_gettingLocation) return;
    setState(() => _gettingLocation = true);

    try {
      final currentLocation = await _locationService.getCurrentLocation();
      final latitude = currentLocation?.latitude;
      final longitude = currentLocation?.longitude;

      if (latitude == null || longitude == null) {
        if (mounted) {
          _showMessage(
            _locationService.lastErrorMessage ??
                'Location permission or GPS service is not available.',
          );
        }
        return;
      }

      if (!LocationService.isInsideMalaysia(latitude, longitude)) {
        if (mounted) {
          _showMessage(
            'The reported GPS position is outside Malaysia. Choose a location on the map instead.',
          );
        }
        return;
      }

      final placeName = await _geocodingService.getPlaceName(
        latitude,
        longitude,
      );
      await _repository.ensureDataNear(latitude, longitude);
      final nearestStop = _repository.findNearestStop(latitude, longitude);
      if (!mounted) return;
      final gpsLocation = JourneyLocation(
        name:
            placeName ??
            (nearestStop == null
                ? 'Current location'
                : 'Near ${nearestStop.name}'),
        latitude: latitude,
        longitude: longitude,
      );

      setState(() {
        _originLocation = gpsLocation;
        _originController.text = gpsLocation.name;
      });
      if (nearestStop != null) {
        _showMessage(
          'GPS selected. Nearest transport stop: ${nearestStop.name}',
        );
      }
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to determine your location. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _gettingLocation = false);
    }
  }

  void _openJourneyOnMap(JourneyOption option) {
    final startingSavedJourney =
        _autoStartSavedJourney ??
        _savedJourneys.cast<SavedJourney?>().firstWhere(
          (journey) => journey?.id == option.id,
          orElse: () => null,
        );
    if (startingSavedJourney != null) {
      _endedJourneyRunKeys.remove(
        LocalStorageService.journeyRunKey(
          startingSavedJourney.id,
          startingSavedJourney.departureTime,
        ),
      );
      unawaited(_clearPersistedJourneyEnd(startingSavedJourney.id));
    }
    setState(() {
      _activeJourney = option;
      _mapRoute = null;
      _activeSavedJourney = startingSavedJourney;
      _autoStartSavedJourney = null;
      _mapKey = UniqueKey();
      _selectedIndex = 2;
    });
  }
  void _openRouteOnMap(TransitRoute route) {
    setState(() {
      _activeJourney = null;
      _activeSavedJourney = null;
      _autoStartSavedJourney = null;
      _mapRoute = route;
      _mapKey = UniqueKey();
      _selectedIndex = 2;
    });
  }

  void _clearActiveJourney() {
    if (_activeJourney == null) return;
    final savedJourney = _activeSavedJourney;
    setState(() {
      _activeJourney = null;
      _activeSavedJourney = null;
      _mapKey = UniqueKey();
    });
    if (savedJourney != null) {
      final key = LocalStorageService.journeyRunKey(
        savedJourney.id,
        savedJourney.departureTime,
      );
      _endedJourneyRunKeys.add(key);
      unawaited(_persistJourneyEnd(savedJourney));
    }
  }

  Future<void> _clearPersistedJourneyEnd(String journeyId) async {
    try {
      await _storage.clearEndedJourneyRun(journeyId);
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to update this journey. Please try again.');
      }
    }
  }

  Future<void> _persistJourneyEnd(SavedJourney journey) async {
    try {
      await _storage.markJourneyRunEnded(
        journeyId: journey.id,
        departureTime: journey.departureTime,
      );
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Journey closed, but its status could not be saved. Please try again.',
        );
      }
    }
  }

  void _startSavedJourney(SavedJourney journey) {
    setState(() {
      _originController.text = journey.origin;
      _destinationController.text = journey.destination;
      _originLocation = journey.originLocation;
      _destinationLocation = journey.destinationLocation;
      _autoStartSavedJourney = journey;
      _plannerKey = UniqueKey();
      _selectedIndex = 1;
    });
  }

  Future<void> _addFavourite() async {
    final type = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return SimpleDialog(
          title: const Text('What do you want to save?'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, 'Route'),
              child: const ListTile(
                leading: Icon(Icons.route),
                title: Text('Route'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, 'Stop'),
              child: const ListTile(
                leading: Icon(Icons.location_on_outlined),
                title: Text('Station or Stop'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, 'Journey'),
              child: const ListTile(
                leading: Icon(Icons.directions),
                title: Text('Saved Journey'),
              ),
            ),
          ],
        );
      },
    );
    if (type == null || !mounted) return;

    if (type == 'Route' || type == 'Stop') {
      var area = _originLocation ?? _destinationLocation;
      if (area == null && _repository.routes.isEmpty) {
        area = await Navigator.push<JourneyLocation>(
          context,
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => SupportedStopMapPicker(
              title: 'Choose an area for official services',
              stops: _repository.stops,
            ),
          ),
        );
        if (area == null || !mounted) return;
      }
      try {
        if (area != null) {
          await _repository.ensureDataNear(area.latitude, area.longitude);
        }
      } catch (_) {
        if (mounted) {
          _showMessage(
            'Unable to load transport information. Please try again.',
          );
        }
        return;
      }
      if (!mounted) return;
    }

    final choices = <_FavouriteChoice>[];
    if (type == 'Route') {
      for (final route in _repository.routes) {
        choices.add(
          _FavouriteChoice(
            title: route.number,
            subtitle: route.name,
            referenceId: route.id,
            type: 'Route',
          ),
        );
      }
    } else if (type == 'Stop') {
      for (final stop in _repository.stops) {
        choices.add(
          _FavouriteChoice(
            title: stop.name,
            subtitle: stop.accessible ? 'Accessible stop' : 'Transport stop',
            referenceId: stop.id,
            type: 'Stop',
          ),
        );
      }
    } else {
      for (final journey in _savedJourneys) {
        choices.add(
          _FavouriteChoice(
            title: '${journey.origin} -> ${journey.destination}',
            subtitle: journey.routeSummary,
            referenceId: journey.id,
            type: 'Journey',
          ),
        );
      }
    }

    if (choices.isEmpty) {
      _showMessage(
        'Save a journey plan first before adding it as a favourite.',
      );
      return;
    }

    final choice = await _chooseFavouriteChoice(type, choices);
    if (choice == null || !mounted) return;

    for (final favourite in _favourites) {
      if (favourite.type == choice.type &&
          favourite.referenceId == choice.referenceId) {
        _showMessage('This item is already in your favourites.');
        return;
      }
    }

    final category = await showDialog<FavouriteCategory>(
      context: context,
      builder: (dialogContext) {
        return SimpleDialog(
          title: const Text('Select a category'),
          children: _categories.map((item) {
            return SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, item),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(item.colourValue),
                  radius: 10,
                ),
                title: Text(item.name),
              ),
            );
          }).toList(),
        );
      },
    );
    if (category == null) return;

    final favourite = FavouriteItem(
      id: 'favourite-${DateTime.now().microsecondsSinceEpoch}',
      title: choice.title,
      subtitle: choice.subtitle,
      type: choice.type,
      referenceId: choice.referenceId,
      categoryId: category.id,
      createdAt: DateTime.now(),
    );

    try {
      await _storage.addFavourite(favourite);
      await _fetchDashboardData();
      _showMessage('Favourite added to ${category.name}.');
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to save this favourite. Please try again.');
      }
    }
  }

  Future<_FavouriteChoice?> _chooseFavouriteChoice(
    String type,
    List<_FavouriteChoice> choices,
  ) {
    var query = '';
    return showDialog<_FavouriteChoice>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final filtered = choices.where((choice) {
            final text = '${choice.title} ${choice.subtitle}'.toLowerCase();
            return text.contains(query.toLowerCase());
          }).toList();
          return AlertDialog(
            title: Text('Select $type'),
            content: SizedBox(
              width: double.maxFinite,
              height: 470,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search official services',
                    ),
                    onChanged: (value) => setDialogState(() => query = value),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('No matching service.'))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final item = filtered[index];
                              return ListTile(
                                leading: Icon(_favouriteIcon(item.type)),
                                title: Text(item.title),
                                subtitle: Text(item.subtitle),
                                onTap: () => Navigator.pop(dialogContext, item),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _manageFavourites() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const FavouriteManagerSheet(),
    );
    await _fetchDashboardData();
  }

  Future<void> _showSavedPlans() async {
    final selected = await showModalBottomSheet<SavedJourney>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SavedJourneyManagerSheet(),
    );
    if (selected != null && mounted) {
      _startSavedJourney(selected);
      return;
    }
    await _fetchDashboardData();
  }

  Future<void> _showUpcomingJourneys() async {
    final selected = await showModalBottomSheet<SavedJourney>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SavedJourneyManagerSheet(upcomingOnly: true),
    );
    if (selected != null && mounted) {
      _startSavedJourney(selected);
      return;
    }
    await _fetchDashboardData();
  }

  Future<void> _openFavourite(FavouriteItem favourite) async {
    if (favourite.type == 'Stop') {
      try {
        await _repository.ensureDataForReference(favourite.referenceId);
      } catch (_) {
        if (mounted) {
          _showMessage('Unable to load this stop. Please try again.');
        }
        return;
      }
      final stop = _repository.findStopById(favourite.referenceId);
      if (stop == null) {
        _showMessage('This stop is no longer present in the official feed.');
        return;
      }
      _openPlanner(destinationLocation: JourneyLocation.fromStop(stop));
      return;
    }

    if (favourite.type == 'Journey') {
      for (final journey in _savedJourneys) {
        if (journey.id == favourite.referenceId) {
          _openPlanner(
            origin: journey.origin,
            destination: journey.destination,
            originLocation: journey.originLocation,
            destinationLocation: journey.destinationLocation,
          );
          return;
        }
      }
      _showMessage('This saved journey is no longer available.');
      return;
    }

    try {
      await _repository.ensureDataForReference(favourite.referenceId);
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to load this route. Please try again.');
      }
      return;
    }
    final route = _repository.findRouteById(favourite.referenceId);
    if (route == null) {
      _showMessage('This route is no longer present in the official feed.');
      return;
    }
    await _showRouteDetails(route);
  }

  Future<void> _openFrequentService(ServiceUsage service) async {
    try {
      await _repository.ensureDataForReference(service.routeId);
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to load this service. Please try again.');
      }
      return;
    }
    final route = _repository.findRouteById(service.routeId);
    if (route == null) {
      _showMessage('This service is no longer present in the official feed.');
      return;
    }
    await _showRouteDetails(route);
  }

  Future<void> _showRouteDetails(TransitRoute route) {
    final stops = _repository.stopsForRoute(route);
    final fee = route.knownFare == null
        ? 'Fee unavailable'
        : 'Official fee: RM ${route.knownFare!.toStringAsFixed(2)}';
    final frequency = route.knownFrequencyMinutes == null
        ? 'See scheduled departures in journey planning'
        : 'Published frequency: every ${route.knownFrequencyMinutes} min';
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${route.number} - ${route.name}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text('${route.mode} · $frequency'),
                    Text(fee),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: stops.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: CircleAvatar(
                      radius: 13,
                      child: Text('${index + 1}'),
                    ),
                    title: Text(stops[index].name),
                    subtitle: stops[index].accessible
                        ? const Text('Wheelchair boarding marked available')
                        : null,
                    onTap: () {
                      Navigator.pop(context);
                      _openPlanner(
                        destinationLocation: JourneyLocation.fromStop(
                          stops[index],
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _openRouteOnMap(route);
                    },
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Show Route on Map'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectedIndex == 0
          ? _buildHomeAppBar()
          : AppBar(
              automaticallyImplyLeading: false,
              title: Text(
                _pageTitles[_selectedIndex],
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
      // Only create the screen that the user opens. This prevents the map,
      // planner and history screens from loading while they are hidden.
      body: _buildSelectedPage(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _changePage,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route),
            label: 'Plan',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedPage() {
    switch (_selectedIndex) {
      case 1:
        return JourneyPlannerScreen(
          key: _plannerKey,
          initialOrigin: _originController.text,
          initialDestination: _destinationController.text,
          initialOriginLocation: _originLocation,
          initialDestinationLocation: _destinationLocation,
          initialSavedJourney: _autoStartSavedJourney,
          onStartJourney: _openJourneyOnMap,
        );
      case 2:
        return TransitMapScreen(
          key: _mapKey,
          journey: _activeJourney,
          initialRoute: _mapRoute,
          onJourneyEnded: _clearActiveJourney,
          onRouteCleared: () {
            if (_mapRoute == null) return;
            setState(() {
              _mapRoute = null;
            });
          },
        );
      case 3:
        return const TravelHistoryScreen();
      case 4:
        return const ProfileScreen();
      default:
        return _buildHomePage();
    }
  }

  PreferredSizeWidget _buildHomeAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: 72,
      title: const Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: Color(0xFFE3F2FD),
            child: Text(
              'UN',
              style: TextStyle(
                color: AppTheme.primaryBlue,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Good Morning,',
                style: TextStyle(fontSize: 12, color: AppTheme.secondaryText),
              ),
              Text(
                'UserName',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.darkBlue,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          onPressed: _fetchDashboardData,
          tooltip: 'Refresh dashboard',
          icon: const Icon(Icons.refresh),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildHomePage() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _fetchDashboardData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          const Row(
            children: [
              Icon(Icons.location_on, color: AppTheme.primaryBlue),
              SizedBox(width: 6),
              Text(
                'Malaysia',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _buildJourneySearchCard(),
          const SizedBox(height: 22),
          const Text(
            'Quick Actions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.05,
            children: [
              _buildQuickAction(
                icon: Icons.route,
                label: 'Plan Journey',
                colour: AppTheme.primaryBlue,
                onTap: () => _openPlanner(),
              ),
              _buildQuickAction(
                icon: Icons.map_outlined,
                label: 'Open Map',
                colour: const Color(0xFF00897B),
                onTap: () => _changePage(2),
              ),
              _buildQuickAction(
                icon: Icons.favorite_border,
                label: 'Add Favourite',
                colour: const Color(0xFFE91E63),
                onTap: _addFavourite,
              ),
              _buildQuickAction(
                icon: Icons.bookmarks_outlined,
                label: 'Saved Plans',
                colour: const Color(0xFFF57C00),
                onTap: _showSavedPlans,
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(
            title: 'Upcoming Journey',
            actionText: 'See All',
            onAction: _showUpcomingJourneys,
          ),
          const SizedBox(height: 12),
          _buildUpcomingJourney(),
          const SizedBox(height: 24),
          _buildSectionHeader(
            title: 'Favourites',
            actionText: 'Manage',
            onAction: _manageFavourites,
          ),
          const SizedBox(height: 10),
          _buildCategoryFilters(),
          const SizedBox(height: 12),
          _buildFavourites(),
          const SizedBox(height: 24),
          _buildSectionHeader(
            title: 'Recent Searches',
            actionText: 'Plan',
            onAction: () => _openPlanner(),
          ),
          const SizedBox(height: 10),
          _buildRecentSearches(),
          const SizedBox(height: 24),
          const Text(
            'Frequently Used Services',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          _buildFrequentServices(),
        ],
      ),
    );
  }

  Widget _buildJourneySearchCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => _selectLocationFromMap(
                  controller: _originController,
                  title: 'Select origin on map',
                  isOrigin: true,
                ),
                tooltip: 'Select origin on map',
                icon: const Icon(
                  Icons.map_outlined,
                  color: AppTheme.primaryBlue,
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _originController,
                  readOnly: true,
                  onTap: () => _selectLocationFromMap(
                    controller: _originController,
                    title: 'Select origin on map',
                    isOrigin: true,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Select origin',
                    filled: false,
                    border: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                onPressed: _gettingLocation ? null : _useGpsForOrigin,
                tooltip: 'Use current GPS location',
                icon: _gettingLocation
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location),
              ),
              IconButton(
                onPressed: _swapLocations,
                icon: const Icon(Icons.swap_vert),
              ),
            ],
          ),
          const Divider(height: 1),
          Row(
            children: [
              IconButton(
                onPressed: () => _selectLocationFromMap(
                  controller: _destinationController,
                  title: 'Select destination on map',
                  isOrigin: false,
                ),
                tooltip: 'Select destination on map',
                icon: const Icon(Icons.location_on, color: Colors.red),
              ),
              Expanded(
                child: TextField(
                  controller: _destinationController,
                  readOnly: true,
                  onTap: () => _selectLocationFromMap(
                    controller: _destinationController,
                    title: 'Select destination on map',
                    isOrigin: false,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Where do you want to go?',
                    filled: false,
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () {
              if (_originLocation == null) {
                _showMessage('Please select an origin or use GPS.');
                return;
              }
              if (_destinationLocation == null) {
                _showMessage('Please select a destination on the map.');
                return;
              }
              _openPlanner(
                originLocation: _originLocation,
                destinationLocation: _destinationLocation,
              );
            },
            icon: const Icon(Icons.route),
            label: const Text('Plan Journey'),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAction({
    required IconData icon,
    required String label,
    required Color colour,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: colour.withValues(alpha: 0.12),
                child: Icon(icon, color: colour),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader({
    required String title,
    required String actionText,
    required VoidCallback onAction,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(onPressed: onAction, child: Text(actionText)),
      ],
    );
  }

  Widget _buildUpcomingJourney() {
    SavedJourney? upcoming;
    final now = MalaysiaTime.now();
    final futureJourneys = _savedJourneys.where((journey) {
      return journey.departureTime.isAfter(now);
    }).toList();
    futureJourneys.sort(
      (first, second) => first.departureTime.compareTo(second.departureTime),
    );
    if (futureJourneys.isNotEmpty) {
      upcoming = futureJourneys.first;
    }

    if (upcoming == null) {
      return _buildEmptyCard(
        icon: Icons.event_available,
        message: 'No upcoming journey. Save a future plan.',
        buttonText: 'Plan Now',
        onPressed: () => _openPlanner(),
      );
    }
    final upcomingJourney = upcoming;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFE3F2FD),
                  child: Icon(Icons.directions, color: AppTheme.primaryBlue),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${upcomingJourney.origin} -> ${upcomingJourney.destination}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${_formatDate(upcomingJourney.departureTime)} at '
                        '${_formatTime(upcomingJourney.departureTime)}',
                        style: const TextStyle(color: AppTheme.secondaryText),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.bookmark, color: AppTheme.primaryBlue),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('${upcomingJourney.durationMinutes} min'),
                const SizedBox(width: 16),
                Text(
                  upcomingJourney.knownFare == null
                      ? 'Fee unavailable'
                      : 'Fee RM ${upcomingJourney.knownFare!.toStringAsFixed(2)}',
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _openPlanner(
                    origin: upcomingJourney.origin,
                    destination: upcomingJourney.destination,
                    originLocation: upcomingJourney.originLocation,
                    destinationLocation: upcomingJourney.destinationLocation,
                  ),
                  child: const Text('View Journey'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryFilters() {
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('All'),
              selected: _selectedCategoryId == null,
              onSelected: (_) {
                setState(() => _selectedCategoryId = null);
              },
            ),
          ),
          for (final category in _categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: CircleAvatar(
                  radius: 6,
                  backgroundColor: Color(category.colourValue),
                ),
                label: Text(category.name),
                selected: _selectedCategoryId == category.id,
                onSelected: (_) {
                  setState(() => _selectedCategoryId = category.id);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFavourites() {
    final visibleFavourites = _favourites.where((item) {
      return _selectedCategoryId == null ||
          item.categoryId == _selectedCategoryId;
    }).toList();

    if (visibleFavourites.isEmpty) {
      return _buildEmptyCard(
        icon: Icons.favorite_border,
        message: 'No favourite in this category yet.',
        buttonText: 'Add Favourite',
        onPressed: _addFavourite,
      );
    }

    return SizedBox(
      height: 125,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: visibleFavourites.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final favourite = visibleFavourites[index];
          return InkWell(
            onTap: () => _openFavourite(favourite),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 155,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _favouriteIcon(favourite.type),
                    color: AppTheme.primaryBlue,
                  ),
                  const Spacer(),
                  Text(
                    favourite.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    favourite.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecentSearches() {
    if (_recentSearches.isEmpty) {
      return _buildEmptyCard(
        icon: Icons.history,
        message: 'Your journey searches will appear here.',
      );
    }

    return Column(
      children: _recentSearches.take(3).map((search) {
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.history, color: AppTheme.primaryBlue),
            title: Text('${search.origin} -> ${search.destination}'),
            subtitle: Text(_formatDate(search.searchedAt)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openPlanner(
              origin: search.origin,
              destination: search.destination,
              originLocation: search.originLocation,
              destinationLocation: search.destinationLocation,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFrequentServices() {
    if (_frequentServices.isEmpty) {
      return _buildEmptyCard(
        icon: Icons.bar_chart,
        message: 'Start journeys to build your frequently used services.',
      );
    }

    return Column(
      children: _frequentServices.map((service) {
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              child: Icon(_modeIcon(service.mode), size: 20),
            ),
            title: Text('${service.routeNumber} - ${service.routeName}'),
            subtitle: Text('${service.usageCount} journey uses'),
            trailing: Text(service.mode),
            onTap: () => _openFrequentService(service),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildEmptyCard({
    required IconData icon,
    required String message,
    String? buttonText,
    VoidCallback? onPressed,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.secondaryText),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
          if (buttonText != null)
            TextButton(onPressed: onPressed, child: Text(buttonText)),
        ],
      ),
    );
  }
}

class FavouriteManagerSheet extends StatefulWidget {
  const FavouriteManagerSheet({super.key});

  @override
  State<FavouriteManagerSheet> createState() => _FavouriteManagerSheetState();
}

class _FavouriteManagerSheetState extends State<FavouriteManagerSheet> {
  final LocalStorageService _storage = LocalStorageService.instance;
  List<FavouriteCategory> _categories = [];
  List<FavouriteItem> _favourites = [];
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _fetchFavourites();
  }

  Future<void> _fetchFavourites() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    try {
      final results = await Future.wait<Object>([
        _storage.getFavouriteCategories(),
        _storage.getFavourites(),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = results[0] as List<FavouriteCategory>;
        _favourites = results[1] as List<FavouriteItem>;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Unable to load favourites. Please try again.';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveFavouriteChange(Future<void> Function() operation) async {
    try {
      await operation();
      await _fetchFavourites();
    } catch (_) {
      if (mounted) {
        _showMessage('Unable to update favourites. Please try again.');
      }
    }
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add Category'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Category name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (name == null) return;
    final validationError = InputValidator.categoryName(name, _categories);
    if (validationError != null) {
      _showMessage(validationError);
      return;
    }
    await _saveFavouriteChange(() async {
      await _storage.addFavouriteCategory(
        name: name.trim(),
        colourValue: 0xFF7B1FA2,
      );
    });
  }

  Future<void> _renameCategory(FavouriteCategory category) async {
    final controller = TextEditingController(text: category.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Rename Category'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Category name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Update'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (name == null) return;
    final validationError = InputValidator.categoryName(
      name,
      _categories,
      ignoredId: category.id,
    );
    if (validationError != null) {
      _showMessage(validationError);
      return;
    }
    await _saveFavouriteChange(
      () => _storage.updateFavouriteCategory(
        category.copyWith(name: name.trim()),
      ),
    );
  }

  Future<void> _deleteCategory(FavouriteCategory category) async {
    if (_categories.length == 1) {
      _showMessage('At least one category is required.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Category?'),
        content: Text(
          'Delete ${category.name}? Its favourites will move to another category.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _saveFavouriteChange(
      () => _storage.deleteFavouriteCategory(category.id),
    );
  }

  Future<void> _moveFavourite(
    FavouriteItem favourite,
    String categoryId,
  ) async {
    await _saveFavouriteChange(
      () =>
          _storage.updateFavourite(favourite.copyWith(categoryId: categoryId)),
    );
  }

  Future<void> _deleteFavourite(FavouriteItem favourite) async {
    await _saveFavouriteChange(() => _storage.deleteFavourite(favourite.id));
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Manage Favourites',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _addCategory,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Category'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _loadError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, size: 44),
                            const SizedBox(height: 10),
                            Text(_loadError!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: _fetchFavourites,
                              child: const Text('Try Again'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Text(
                          'Categories',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        for (final category in _categories)
                          Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                radius: 10,
                                backgroundColor: Color(category.colourValue),
                              ),
                              title: Text(category.name),
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'rename') {
                                    _renameCategory(category);
                                  } else {
                                    _deleteCategory(category);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                        const Text(
                          'Favourite Items',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        if (_favourites.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'No favourites have been added.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        for (final favourite in _favourites)
                          Card(
                            child: ListTile(
                              leading: Icon(_favouriteIcon(favourite.type)),
                              title: Text(favourite.title),
                              subtitle: DropdownButton<String>(
                                value: favourite.categoryId,
                                isExpanded: true,
                                underline: const SizedBox(),
                                items: _categories.map((category) {
                                  return DropdownMenuItem<String>(
                                    value: category.id,
                                    child: Text(category.name),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    _moveFavourite(favourite, value);
                                  }
                                },
                              ),
                              trailing: IconButton(
                                onPressed: () => _deleteFavourite(favourite),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavouriteChoice {
  const _FavouriteChoice({
    required this.title,
    required this.subtitle,
    required this.referenceId,
    required this.type,
  });

  final String title;
  final String subtitle;
  final String referenceId;
  final String type;
}

IconData _favouriteIcon(String type) {
  if (type == 'Route') return Icons.route;
  if (type == 'Stop') return Icons.location_on_outlined;
  return Icons.directions;
}

IconData _modeIcon(String mode) {
  if (mode == 'Bus') return Icons.directions_bus;
  if (mode == 'MRT') return Icons.subway;
  if (mode == 'LRT') return Icons.tram;
  if (mode == 'KTM') return Icons.train;
  if (mode == 'Monorail') return Icons.commute;
  if (mode == 'Ferry') return Icons.directions_boat;
  return Icons.directions_transit;
}

String _formatDate(DateTime value) {
  final day = value.day.toString().padLeft(2, '0');
  final month = value.month.toString().padLeft(2, '0');
  return '$day/$month/${value.year}';
}

String _formatTime(DateTime value) {
  var hour = value.hour;
  final period = hour >= 12 ? 'PM' : 'AM';
  if (hour == 0) hour = 12;
  if (hour > 12) hour -= 12;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute $period';
}
