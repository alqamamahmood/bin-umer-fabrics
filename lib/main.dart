import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:binumerfabrics_app/lang.dart';

// Bin Umer Fabrics — standalone fabric store app (website se KOI taluq nahi).
// FRONTEND ONLY (v1 preview): koi backend nahi — products, orders, banners,
// settings sab is device par SharedPreferences mein save hote hain.
// Checkout mein phone OTP nahi hai; order seedha Admin Panel > Orders mein dikhta hai.
const String kAdminPin = '786';
const String kShopAddress = 'Bin Umer Fabrics, Pak Gate, Sarafa Bazaar, Multan';

// Premium theme — deep navy + gold + ivory.
const Color kPrimary = Color(0xFF0F1E33);
const Color kPrimaryDark = Color(0xFF0A1526);
const Color kAccent = Color(0xFFC9A227);
const Color kAccentDark = Color(0xFF9A7B1A);
const Color kBg = Color(0xFFFAF7F0);
const Color kText = Color(0xFF1F2937);

String rs(int v) => 'Rs ${v.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';

Future<void> openTel(String number) async {
  final uri = Uri.parse('tel:$number');
  if (!await launchUrl(uri)) throw Exception(tr('call_failed'));
}

// ---------------- Local store (offline — SharedPreferences) ----------------
// Backend ke baghair: sab kuch is device par save hota hai. Baad mein Firebase
// lagane par inhi function ke naam waisay hi rahenge, andar ki implementation badlegi.
class LocalStore {
  static const _kProducts = 'bu_products';
  static const _kOrders = 'bu_orders';
  static const _kBanners = 'bu_banners';
  static const _kSettings = 'bu_settings';

  static List<Map<String, dynamic>> decodeList(String? raw) {
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Map<String, dynamic> decodeMap(String? raw) {
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static String _hex(Color c) => '#${c.value.toRadixString(16).substring(2).toUpperCase()}';

  /// Pehla launch: bundled catalog/banners/settings seed karo.
  static Future<void> ensureReady() async {
    final p = await SharedPreferences.getInstance();
    if (p.getString(_kProducts) == null) {
      await p.setString(_kProducts, jsonEncode(kFallback.map((e) => e.toLocalJson()).toList()));
    }
    if (p.getString(_kBanners) == null) {
      await p.setString(_kBanners, jsonEncode(kFallbackBanners.map((b) => {
            'title': b.title,
            'subtitle': b.subtitle,
            'emoji': b.emoji,
            'category': b.category,
            'gradient_from': _hex(b.from),
            'gradient_to': _hex(b.to),
            'sort_order': 0,
            'active': true,
          }).toList()));
    }
    if (p.getString(_kSettings) == null) {
      await p.setString(_kSettings, jsonEncode({'delivery_fee': 200, 'announcement': '', ...kDefaultFees}));
    }
  }

  static Future<void> saveProducts(List<Product> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kProducts, jsonEncode(list.map((e) => e.toLocalJson()).toList()));
  }
}

/// App start par local store tayyar karo (seed agar pehli dafa hai).
Future<void> ensureLocalReady() async => LocalStore.ensureReady();

Future<List<Product>> fetchRemoteProducts() async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kProducts));
  if (list.isEmpty) return List.of(kFallback);
  final out = list.map((e) => Product.fromLocalJson(e)).toList();
  out.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return out;
}

Future<String?> insertOrder({
  required String name,
  required String phone,
  required String address,
  required String city,
  required List<Map<String, dynamic>> items,
  required int subtotal,
  required int delivery,
  required int total,
  String deliverySpeed = '',
  String deliveryArea = '',
}) async {
  final p = await SharedPreferences.getInstance();
  final orders = LocalStore.decodeList(p.getString(LocalStore._kOrders));
  final id = 'ord-${DateTime.now().millisecondsSinceEpoch}';
  orders.insert(0, {
    'id': id,
    'customer_name': name,
    'customer_phone': normPhone(phone),
    'address': address,
    'city': city,
    'items': items,
    'subtotal': subtotal,
    'delivery': delivery,
    'total': total,
    'delivery_speed': deliverySpeed,
    'delivery_area': deliveryArea,
    'status': 'Naya',
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });
  await p.setString(LocalStore._kOrders, jsonEncode(orders));
  return id;
}

Future<List<FabricOrder>> fetchRemoteOrders() async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kOrders));
  final out = list.map((e) => FabricOrder.fromJson(e)).toList();
  out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

Future<void> updateOrderStatus(String id, String status) async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kOrders));
  final idx = list.indexWhere((e) => '${e['id']}' == id);
  if (idx < 0) return;
  list[idx]['status'] = status;
  await p.setString(LocalStore._kOrders, jsonEncode(list));
}

Future<Product> upsertProduct(Product p) async {
  final prefs = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(prefs.getString(LocalStore._kProducts));
  final data = p.toLocalJson();
  final idx = list.indexWhere((e) => '${e['id']}' == p.id);
  if (idx >= 0) {
    // Rating/review fields admin edit se overwrite na hon.
    data['rating_sum'] = list[idx]['rating_sum'];
    data['rating_count'] = list[idx]['rating_count'];
    data['reviews'] = list[idx]['reviews'];
    list[idx] = data;
  } else {
    data['id'] = 'local-${DateTime.now().millisecondsSinceEpoch}';
    list.add(data);
  }
  await prefs.setString(LocalStore._kProducts, jsonEncode(list));
  return Product.fromLocalJson(data);
}

Future<void> deleteRemoteProduct(String id) async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kProducts));
  list.removeWhere((e) => '${e['id']}' == id);
  await p.setString(LocalStore._kProducts, jsonEncode(list));
}

/// Tasveer ko chhota kar ke data-URI string banata hai, jo product ke record
/// mein hi save hoti hai (koi cloud storage nahi).
Future<String> uploadProductImage(XFile file) async {
  final bytes = await file.readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw Exception(tr('image_unreadable'));
  var width = 800;
  var quality = 72;
  List<int> jpg = [];
  for (var attempt = 0; attempt < 3; attempt++) {
    final resized = decoded.width > width ? img.copyResize(decoded, width: width) : decoded;
    jpg = img.encodeJpg(resized, quality: quality);
    if (jpg.length <= 700 * 1024) break;
    width = width == 800 ? 600 : 480;
    quality = quality == 72 ? 60 : 50;
  }
  return 'data:image/jpeg;base64,${base64Encode(jpg)}';
}

Future<List<AppBanner>> fetchRemoteBanners() async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kBanners));
  return list.where((m) => m['active'] == true || m['active'] == 1).map((m) => AppBanner.fromJson(m)).toList();
}

Future<Map<String, dynamic>> fetchRemoteSettings() async {
  final p = await SharedPreferences.getInstance();
  final map = LocalStore.decodeMap(p.getString(LocalStore._kSettings));
  if (map.isEmpty) return {'delivery_fee': 200, 'announcement': '', ...kDefaultFees};
  return map;
}

Future<List<AdminBanner>> fetchAllBanners() async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kBanners));
  return list.map((e) => AdminBanner.fromJson(e)).toList();
}

Future<void> upsertBanner(AdminBanner b) async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kBanners));
  final data = b.toRemoteJson();
  if (b.id.startsWith('new-')) {
    data['id'] = 'bn-${DateTime.now().millisecondsSinceEpoch}';
    list.add(data);
  } else {
    final idx = list.indexWhere((e) => '${e['id']}' == b.id);
    data['id'] = b.id;
    if (idx >= 0) {
      list[idx] = data;
    } else {
      list.add(data);
    }
  }
  await p.setString(LocalStore._kBanners, jsonEncode(list));
}

Future<void> deleteRemoteBanner(String id) async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kBanners));
  list.removeWhere((e) => '${e['id']}' == id);
  await p.setString(LocalStore._kBanners, jsonEncode(list));
}

Future<void> updateRemoteSetting(String key, String value) async {
  final p = await SharedPreferences.getInstance();
  final map = LocalStore.decodeMap(p.getString(LocalStore._kSettings));
  map[key] = value;
  await p.setString(LocalStore._kSettings, jsonEncode(map));
}

/// Phone number ko aik shakal mein lao (muqable ke liye).
String normPhone(String phone) {
  var d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('92') && d.length == 12) d = '0${d.substring(2)}';
  return d;
}

/// Is phone ke orders (local).
Future<List<FabricOrder>> fetchOrdersByPhone(String phone) async {
  final want = normPhone(phone);
  final all = await fetchRemoteOrders();
  return all.where((o) => normPhone(o.phone) == want).toList();
}

/// Customer review: product ke local record mein review jama + counters barhao.
Future<void> submitProductReview(String productId, {required String name, required int rating, required String comment}) async {
  final p = await SharedPreferences.getInstance();
  final list = LocalStore.decodeList(p.getString(LocalStore._kProducts));
  final idx = list.indexWhere((e) => '${e['id']}' == productId);
  if (idx < 0) return;
  final data = Map<String, dynamic>.from(list[idx]);
  final reviews = (data['reviews'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? <Map<String, dynamic>>[];
  reviews.add({'name': name, 'rating': rating, 'comment': comment, 'created_ms': DateTime.now().millisecondsSinceEpoch});
  data['reviews'] = reviews;
  data['rating_sum'] = ((data['rating_sum'] as num?)?.toInt() ?? 0) + rating;
  data['rating_count'] = ((data['rating_count'] as num?)?.toInt() ?? 0) + 1;
  list[idx] = data;
  await p.setString(LocalStore._kProducts, jsonEncode(list));
}

// ---------------- Star rating widgets ----------------
Widget starRow(double avg, {double size = 16, Color? color}) {
  final c = color ?? Colors.amber[700]!;
  final full = avg.floor();
  final half = (avg - full) >= 0.5;
  return Row(mainAxisSize: MainAxisSize.min, children: [
    for (var i = 0; i < 5; i++)
      Icon(
        i < full
            ? Icons.star
            : (i == full && half ? Icons.star_half : Icons.star_border),
        size: size,
        color: c,
      ),
  ]);
}

String reviewDateText(dynamic ms) {
  try {
    final d = DateTime.fromMillisecondsSinceEpoch((ms as num).toInt()).toLocal();
    return '${d.day}/${d.month}/${d.year}';
  } catch (_) {
    return '';
  }
}

class AdminBanner {
  final String id;
  final String title;
  final String subtitle;
  final String emoji;
  final String category;
  final String gradientFrom;
  final String gradientTo;
  final int sortOrder;
  final bool active;
  AdminBanner({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.emoji = '',
    this.category = 'Sab',
    this.gradientFrom = '#0F1E33',
    this.gradientTo = '#0A1526',
    this.sortOrder = 0,
    this.active = true,
  });

  factory AdminBanner.fromJson(Map<String, dynamic> j) => AdminBanner(
        id: '${j['id']}',
        title: j['title'] ?? '',
        subtitle: j['subtitle'] ?? '',
        emoji: j['emoji'] ?? '',
        category: j['category'] ?? 'Sab',
        gradientFrom: j['gradient_from'] ?? '#0F1E33',
        gradientTo: j['gradient_to'] ?? '#0A1526',
        sortOrder: (j['sort_order'] is int) ? j['sort_order'] as int : int.tryParse('${j['sort_order']}') ?? 0,
        active: j['active'] == true || j['active'] == 1,
      );

  Map<String, dynamic> toRemoteJson() => {
        'title': title,
        'subtitle': subtitle,
        'emoji': emoji,
        'category': category,
        'gradient_from': gradientFrom,
        'gradient_to': gradientTo,
        'sort_order': sortOrder,
        'active': active,
      };
}

// ---------------- Models ----------------
class Product {
  final String id;
  final String name;
  final String urdu;
  final int? price;
  final String? image;
  final String desc;
  final String category;
  final bool freeDelivery;
  final int sortOrder;
  final int ratingSum;
  final int ratingCount;
  final List<Map<String, dynamic>> reviews;
  Product({
    required this.id,
    required this.name,
    this.urdu = '',
    this.price,
    this.image,
    this.desc = '',
    this.category = 'Herbal',
    this.freeDelivery = false,
    this.sortOrder = 0,
    this.ratingSum = 0,
    this.ratingCount = 0,
    this.reviews = const [],
  });

  double get averageRating => ratingCount == 0 ? 0 : ratingSum / ratingCount;

  /// Urdu mode mein Urdu naam (agar darj hai), warna English/Roman naam.
  String get displayName => appLang == 'ur' && urdu.isNotEmpty ? urdu : name;

  Product copyWith({
    String? id,
    String? name,
    String? urdu,
    int? price,
    String? image,
    String? desc,
    String? category,
    bool? freeDelivery,
    int? sortOrder,
    int? ratingSum,
    int? ratingCount,
    List<Map<String, dynamic>>? reviews,
  }) {
    return Product(
      id: id ?? this.id,
      name: name ?? this.name,
      urdu: urdu ?? this.urdu,
      price: price ?? this.price,
      image: image ?? this.image,
      desc: desc ?? this.desc,
      category: category ?? this.category,
      freeDelivery: freeDelivery ?? this.freeDelivery,
      sortOrder: sortOrder ?? this.sortOrder,
      ratingSum: ratingSum ?? this.ratingSum,
      ratingCount: ratingCount ?? this.ratingCount,
      reviews: reviews ?? this.reviews,
    );
  }

  factory Product.fromJson(Map<String, dynamic> j) {
    int? price;
    final rawPrice = j['price'];
    if (rawPrice is int) price = rawPrice;
    if (rawPrice is String) price = int.tryParse(rawPrice);
    int sortOrder = 0;
    if (j['sort_order'] is int) sortOrder = j['sort_order'] as int;
    if (j['sortOrder'] is int) sortOrder = j['sortOrder'] as int;
    List<Map<String, dynamic>> reviews = [];
    final rawReviews = j['reviews'];
    if (rawReviews is List) {
      reviews = rawReviews.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return Product(
      id: '${j['id']}',
      name: j['name'] ?? '',
      urdu: j['urdu'] ?? '',
      price: price,
      image: j['image_url'] ?? j['image'],
      desc: j['description'] ?? j['desc'] ?? '',
      category: j['category'] ?? 'Herbal',
      freeDelivery: j['free_delivery'] == true || j['free_delivery'] == 1 || j['freeDelivery'] == true,
      sortOrder: sortOrder,
      ratingSum: (j['rating_sum'] as num?)?.toInt() ?? (j['ratingSum'] as num?)?.toInt() ?? 0,
      ratingCount: (j['rating_count'] as num?)?.toInt() ?? (j['ratingCount'] as num?)?.toInt() ?? 0,
      reviews: reviews,
    );
  }

  factory Product.fromLocalJson(Map<String, dynamic> j) => Product.fromJson(j);

  // NOTE: rating fields toRemoteJson mein NAHI hain — admin ki product edit
  // kabhi ratings/reviews ko overwrite na kare. Ratings sirf review flow likhta hai.
  Map<String, dynamic> toRemoteJson() => {
        'name': name,
        'urdu': urdu,
        'price': price,
        'image_url': image,
        'description': desc,
        'category': category,
        'free_delivery': freeDelivery,
        'sort_order': sortOrder,
      };

  Map<String, dynamic> toLocalJson() => {
        'id': id,
        'name': name,
        'urdu': urdu,
        'price': price,
        'image': image,
        'desc': desc,
        'category': category,
        'freeDelivery': freeDelivery,
        'sortOrder': sortOrder,
        'rating_sum': ratingSum,
        'rating_count': ratingCount,
        'reviews': reviews,
      };
}

class AppBanner {
  final String title;
  final String subtitle;
  final String emoji;
  final String category;
  final Color from;
  final Color to;
  AppBanner({required this.title, required this.subtitle, required this.emoji, required this.category, required this.from, required this.to});

  factory AppBanner.fromJson(Map<String, dynamic> j) => AppBanner(
        title: j['title'] ?? '',
        subtitle: j['subtitle'] ?? '',
        emoji: j['emoji'] ?? '',
        category: j['category'] ?? 'Sab',
        from: _hexColor(j['gradient_from']),
        to: _hexColor(j['gradient_to']),
      );
}

// ---------------- Product categories (admin se banai ja sakti hain) ----------------
class AppCategory {
  final String name;
  final String icon;
  const AppCategory(this.name, this.icon);
  Map<String, dynamic> toJson() => {'name': name, 'icon': icon};
  factory AppCategory.fromJson(Map<String, dynamic> j) => AppCategory('${j['name'] ?? ''}', '${j['icon'] ?? 'category'}');
}

const List<AppCategory> kDefaultCategories = [
  AppCategory('Wash & Wear', 'drop'),
  AppCategory('Boski', 'star'),
  AppCategory('Cotton', 'flower'),
  AppCategory('Lawn', 'leaf'),
  AppCategory('Khaddar', 'grain'),
  AppCategory('Karandi', 'box'),
];

const Map<String, IconData> kCategoryIcons = {
  'drop': Icons.opacity,
  'leaf': Icons.eco,
  'honey': Icons.water_drop,
  'spa': Icons.spa,
  'apps': Icons.apps,
  'grain': Icons.grass,
  'bottle': Icons.local_drink,
  'box': Icons.inventory_2,
  'star': Icons.star,
  'flower': Icons.local_florist,
  'category': Icons.category,
};

List<AppCategory> parseCategories(dynamic raw) {
  if (raw is! List || raw.isEmpty) return List.of(kDefaultCategories);
  final out = <AppCategory>[];
  for (final e in raw) {
    if (e is Map) {
      final c = AppCategory.fromJson(Map<String, dynamic>.from(e));
      if (c.name.isNotEmpty) out.add(c);
    }
  }
  return out.isEmpty ? List.of(kDefaultCategories) : out;
}

Future<void> saveRemoteCategories(List<AppCategory> cats) async {
  final p = await SharedPreferences.getInstance();
  final map = LocalStore.decodeMap(p.getString(LocalStore._kSettings));
  map['categories'] = cats.map((c) => c.toJson()).toList();
  await p.setString(LocalStore._kSettings, jsonEncode(map));
}

Color _hexColor(dynamic v) {
  try {
    final s = '$v'.replaceFirst('#', '');
    return Color(int.parse('ff$s', radix: 16));
  } catch (_) {
    return kPrimary;
  }
}

DateTime _parseCreatedAt(dynamic v) {
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  return DateTime.tryParse('$v') ?? DateTime.now();
}

class FabricOrder {
  final String id;
  final String name;
  final String phone;
  final String address;
  final String city;
  final List<Map<String, dynamic>> items;
  final int subtotal;
  final int delivery;
  final int total;
  final String status;
  final String deliverySpeed;
  final String deliveryArea;
  final DateTime createdAt;
  FabricOrder({
    required this.id,
    required this.name,
    required this.phone,
    required this.address,
    required this.city,
    required this.items,
    required this.subtotal,
    required this.delivery,
    required this.total,
    required this.status,
    this.deliverySpeed = '',
    this.deliveryArea = '',
    required this.createdAt,
  });

  factory FabricOrder.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> items = [];
    final raw = j['items'];
    if (raw is List) {
      items = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return FabricOrder(
      id: '${j['id']}',
      name: j['customer_name'] ?? '',
      phone: j['customer_phone'] ?? '',
      address: j['address'] ?? '',
      city: j['city'] ?? '',
      items: items,
      subtotal: (j['subtotal'] as num?)?.toInt() ?? 0,
      delivery: (j['delivery'] as num?)?.toInt() ?? 0,
      total: (j['total'] as num?)?.toInt() ?? 0,
      status: j['status'] ?? 'Naya',
      deliverySpeed: j['delivery_speed'] ?? '',
      deliveryArea: j['delivery_area'] ?? '',
      createdAt: _parseCreatedAt(j['created_at']),
    );
  }

  String get dateText {
    final d = createdAt.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day}/${d.month}/${d.year} $hh:$mm';
  }
}

class CartItem {
  final String id;
  final String name;
  final String urdu;
  final int price;
  final String? image;
  int qty;
  CartItem({required this.id, required this.name, this.urdu = '', required this.price, this.image, required this.qty});
  String get displayName => appLang == 'ur' && urdu.isNotEmpty ? urdu : name;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'urdu': urdu, 'price': price, 'image': image, 'qty': qty};
  factory CartItem.fromJson(Map<String, dynamic> j) =>
      CartItem(id: j['id'], name: j['name'], urdu: j['urdu'] ?? '', price: j['price'], image: j['image'], qty: j['qty']);
}

// Bundled catalog — 12 sample men's unstitched suits (Rs 2,000–7,000).
// Sample hain — Admin Panel > Products se photo/qeemat badli ja sakti hai.
final List<Product> kFallback = [
  Product(id: 'fb-ww-white', name: 'Wash & Wear Classic White', urdu: 'واش اینڈ ویئر کلاسک سفید', price: 2499, desc: 'Soft, wrinkle-free wash & wear. Garmiyon ke liye behtareen, halka aur aramdeh.', category: 'Wash & Wear', sortOrder: 1),
  Product(id: 'fb-ww-navy', name: 'Wash & Wear Premium Navy', urdu: 'واش اینڈ ویئر پریمیم نیوی', price: 3499, desc: 'Premium navy wash & wear. Gehra rang, naram kapra, rozana pehnne ke liye.', category: 'Wash & Wear', sortOrder: 2),
  Product(id: 'fb-ww-gold', name: 'Wash & Wear Royal Gold', urdu: 'واش اینڈ ویئر رائل گولڈ', price: 4999, desc: 'Royal gold wash & wear. Khas mauqon ke liye premium quality.', category: 'Wash & Wear', freeDelivery: true, sortOrder: 3),
  Product(id: 'fb-boski-classic', name: 'Boski Classic', urdu: 'بوسکی کلاسک', price: 5999, desc: 'Asli boski — chamakdar, halki aur naram. Classic mardana suit.', category: 'Boski', freeDelivery: true, sortOrder: 4),
  Product(id: 'fb-boski-premium', name: 'Boski Premium', urdu: 'بوسکی پریمیم', price: 6999, desc: 'Premium grade boski. Behtareen chamak aur girawat, shaadi-biyah ke liye.', category: 'Boski', freeDelivery: true, sortOrder: 5),
  Product(id: 'fb-cotton-white', name: 'Cotton Soft White', urdu: 'کاٹن نرم سفید', price: 2999, desc: 'Naram suoti kapra. Saans lene wala, garmiyon mein thandak.', category: 'Cotton', sortOrder: 6),
  Product(id: 'fb-cotton-grey', name: 'Cotton Premium Grey', urdu: 'کاٹن پریمیم گرے', price: 4499, desc: 'Premium grey cotton. Mazboot bunai, lamba arsa chalne wala.', category: 'Cotton', sortOrder: 7),
  Product(id: 'fb-lawn-sky', name: 'Lawn Summer Sky', urdu: 'لان سمر اسکائی', price: 2000, desc: 'Halki phulki summer lawn. Garmi mein aram aur tazgi.', category: 'Lawn', sortOrder: 8),
  Product(id: 'fb-lawn-floral', name: 'Lawn Floral Light', urdu: 'لان فلورل لائٹ', price: 3000, desc: 'Floral print lawn. Halka, naram aur khubsurat.', category: 'Lawn', sortOrder: 9),
  Product(id: 'fb-khaddar-warm', name: 'Khaddar Winter Warm', urdu: 'کھڈر سردیوں والا', price: 2499, desc: 'Garm khaddar. Sardiyon ke liye behtareen, mazboot aur garam.', category: 'Khaddar', sortOrder: 10),
  Product(id: 'fb-khaddar-brown', name: 'Khaddar Classic Brown', urdu: 'کھڈر کلاسک براؤن', price: 3999, desc: 'Classic brown khaddar. Sardiyon ka premium mardana suit.', category: 'Khaddar', sortOrder: 11),
  Product(id: 'fb-karandi-luxury', name: 'Karandi Luxury', urdu: 'کرنڈی لگژری', price: 5499, desc: 'Luxury karandi. Naram, chamakdar aur shaandaar — khaas mauqon ke liye.', category: 'Karandi', freeDelivery: true, sortOrder: 12),
];

final List<AppBanner> kFallbackBanners = [
  AppBanner(title: "Premium Men's Unstitched Suits", subtitle: 'Wash & Wear • Boski • Cotton — Rs 2,000 se Rs 7,000', emoji: '🧵', category: 'Sab', from: kPrimary, to: kPrimaryDark),
  AppBanner(title: 'New Season Collection', subtitle: 'Lawn • Khaddar • Karandi — naye design', emoji: '👔', category: 'Sab', from: kAccent, to: kAccentDark),
  AppBanner(title: 'Cash on Delivery', subtitle: 'Multan aur puray Pakistan mein — ghar baithe order karein', emoji: '🚚', category: 'Sab', from: const Color(0xFF1E3A5F), to: const Color(0xFF0F1E33)),
];

// Delivery fees (flat, offline): Multan ke andar Normal Rs 200, Medium Rs 250,
// Urgent Rs 300; city se bahir Rs 299. Fees Settings mein hain — Admin Panel
// se kabhi bhi badli ja sakti hain.
const Map<String, int> kDefaultFees = {
  'fee_near_normal': 200, 'fee_near_medium': 250, 'fee_near_urgent': 300,
  'fee_mid_normal': 200, 'fee_mid_medium': 250, 'fee_mid_urgent': 300,
  'fee_far_normal': 200, 'fee_far_medium': 250, 'fee_far_urgent': 300,
  'fee_outside': 299,
};

/// Purana rule (Urgent = Normal + 150) badal gaya hai. Agar settings mein
/// purani default Urgent qeemat save hai to nayi default (Normal + 100) lao.
int migrateFeeValue(String key, int value) {
  if (key == 'fee_near_urgent' && value == 250) return 200;
  if (key == 'fee_mid_urgent' && value == 350) return 300;
  if (key == 'fee_far_urgent' && value == 450) return 400;
  return value;
}
const List<String> kDeliverySpeeds = ['Normal', 'Medium', 'Urgent'];
const List<String> kDeliverySpeedHints = ['6 ghante mein', '3 se 4 ghante mein', '1 ghante mein'];
const List<String> kDeliveryAreas = ['Qareeb (0-3 km)', 'Darmiyana (3-7 km)', 'Door (7-12 km)', 'City se bahir (1-7 din)'];

int deliveryFeeFor(Map<String, int> table, int areaIdx, int speedIdx, bool hasFree) {
  if (areaIdx == 3) return table['fee_outside'] ?? kDefaultFees['fee_outside']!;
  final areaKey = ['near', 'mid', 'far'][areaIdx];
  final speedKey = ['normal', 'medium', 'urgent'][speedIdx];
  final key = 'fee_${areaKey}_$speedKey';
  final fee = table[key] ?? kDefaultFees[key] ?? 0;
  if (!hasFree) return fee;
  // Free-delivery wali cheez: Normal muft; Medium/Urgent par sirf raftaar ka
  // farq — Medium Normal se 50 zyada, Urgent 100 zyada (table se hisab).
  if (speedIdx == 0) return 0;
  final normalFee = table['fee_${areaKey}_normal'] ?? kDefaultFees['fee_${areaKey}_normal'] ?? 0;
  final extra = fee - normalFee;
  return extra > 0 ? extra : 0;
}

// Admin ki upload ki hui tasveer (data-URI) pehle; warna naam se bundled swatch.
String? assetImageFor(Product p) {
  final n = p.name.toLowerCase();
  if (n.contains('wash')) return 'assets/products/washwear.jpg';
  if (n.contains('boski')) return 'assets/products/boski.jpg';
  if (n.contains('cotton')) return 'assets/products/cotton.jpg';
  if (n.contains('lawn')) return 'assets/products/lawn.jpg';
  if (n.contains('khaddar')) return 'assets/products/khaddar.jpg';
  if (n.contains('karandi')) return 'assets/products/karandi.jpg';
  return null;
}

Widget productImageWidget(Product p) {
  if (p.image != null && p.image!.isNotEmpty) {
    if (p.image!.startsWith('data:image')) {
      try {
        final bytes = base64Decode(p.image!.split(',').last);
        return Image.memory(bytes, fit: BoxFit.cover, width: double.infinity, height: double.infinity,
            errorBuilder: (_, __, ___) => _assetOrFallback(p));
      } catch (_) {
        return _assetOrFallback(p);
      }
    }
    return Image.network(p.image!, fit: BoxFit.cover, width: double.infinity, height: double.infinity,
        errorBuilder: (_, __, ___) => _assetOrFallback(p));
  }
  return _assetOrFallback(p);
}

Widget _assetOrFallback(Product p) {
  final a = assetImageFor(p);
  if (a != null) return Image.asset(a, fit: BoxFit.cover, width: double.infinity, height: double.infinity);
  return Container(color: const Color(0xFFEDE7D9), width: double.infinity, height: double.infinity, child: const Center(child: Text('🧵', style: TextStyle(fontSize: 44))));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  appLang = prefs.getString(kLangPrefKey) ?? 'en';
  await ensureLocalReady();
  runApp(const BinUmerFabricsApp());
}

class BinUmerFabricsApp extends StatelessWidget {
  const BinUmerFabricsApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bin Umer Fabrics',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: kPrimary,
        scaffoldBackgroundColor: kBg,
        appBarTheme: const AppBarTheme(backgroundColor: kPrimary, foregroundColor: Colors.white, elevation: 0),
        colorScheme: ColorScheme.fromSeed(seedColor: kPrimary),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  List<Product> _products = kFallback;
  List<CartItem> _cart = [];
  Set<String> _favs = {};
  List<AppBanner> _banners = kFallbackBanners;
  final Map<String, int> _feeTable = Map.of(kDefaultFees);
  String _announcement = '';
  String _profileName = '';
  String _profilePhone = '';
  List<Map<String, String>> _addresses = [];
  final PageController _bannerCtrl = PageController();
  Timer? _bannerTimer;
  int _bannerIndex = 0;
  int _versionTaps = 0;
  DateTime? _lastVersionTap;

  List<AppCategory> _categories = List.of(kDefaultCategories);

  List<String> get _chipCats => ['Sab', ..._categories.map((c) => c.name)];

  IconData _iconFor(String name) {
    if (name == 'Sab') return Icons.apps;
    for (final c in _categories) {
      if (c.name == name) return kCategoryIcons[c.icon] ?? Icons.category;
    }
    return Icons.category;
  }

  Future<void> _saveCategoriesCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_categories', jsonEncode(_categories.map((c) => c.toJson()).toList()));
  }

  @override
  void initState() {
    super.initState();
    _loadLocal();
    _loadProducts();
    _loadBannersAndSettings();
    _bannerTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _bannerCtrl.positions.isEmpty) return;
      final next = (_bannerIndex + 1) % _banners.length;
      _bannerCtrl.animateToPage(next, duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    });
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _bannerCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final rawCart = prefs.getString('cart');
      if (rawCart != null) _cart = (jsonDecode(rawCart) as List).map((e) => CartItem.fromJson(e as Map<String, dynamic>)).toList();
      final rawFavs = prefs.getStringList('favourites');
      if (rawFavs != null) _favs = rawFavs.toSet();
      _profileName = prefs.getString('profile_name') ?? '';
      _profilePhone = prefs.getString('profile_phone') ?? '';
      final rawAddr = prefs.getString('addresses');
      if (rawAddr != null) {
        _addresses = (jsonDecode(rawAddr) as List).map((e) => Map<String, String>.from(e as Map)).toList();
      }
      final rawCats = prefs.getString('app_categories');
      if (rawCats != null) {
        try {
          final list = (jsonDecode(rawCats) as List).map((e) => AppCategory.fromJson(Map<String, dynamic>.from(e as Map))).where((c) => c.name.isNotEmpty).toList();
          if (list.isNotEmpty) _categories = list;
        } catch (_) {}
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _saveCart() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cart', jsonEncode(_cart.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveFavs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favourites', _favs.toList());
  }

  Future<void> _saveProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_name', _profileName);
    await prefs.setString('profile_phone', _profilePhone);
  }

  Future<void> _saveAddresses() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('addresses', jsonEncode(_addresses));
  }

  Future<void> _refreshAll() async {
    await _loadProducts();
    await _loadBannersAndSettings();
  }

  Future<void> _loadProducts() async {
    try {
      final remote = await fetchRemoteProducts();
      if (remote.isNotEmpty && mounted) {
        setState(() {
          _products = remote;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadBannersAndSettings() async {
    try {
      final banners = await fetchRemoteBanners();
      if (banners.isNotEmpty && mounted) setState(() => _banners = banners);
    } catch (_) {}
    try {
      final s = await fetchRemoteSettings();
      if (mounted) {
        setState(() {
          for (final k in kDefaultFees.keys) {
            _feeTable[k] = migrateFeeValue(k, int.tryParse('${s[k] ?? ''}') ?? kDefaultFees[k]!);
          }
          _announcement = '${s['announcement'] ?? ''}';
          _categories = parseCategories(s['categories']);
        });
        unawaited(_saveCategoriesCache());
      }
    } catch (_) {}
  }

  Future<void> _saveProductsLocal() async {
    await LocalStore.saveProducts(_products);
  }

  int get _cartCount => _cart.fold(0, (s, e) => s + e.qty);
  int get _subtotal => _cart.fold(0, (s, e) => s + e.price * e.qty);
  bool get _hasFreeDelivery {
    return _cart.any((e) {
      final p = _products.where((x) => x.id == e.id).toList();
      return p.isNotEmpty && p.first.freeDelivery;
    });
  }
  // Cart mein andaza fee (Qareeb + Normal) — asal fee checkout par speed/area se tay hoti hai.
  int get _delivery {
    if (_cart.isEmpty) return 0;
    return _hasFreeDelivery ? 0 : (_feeTable['fee_near_normal'] ?? 100);
  }
  int get _total => _subtotal + _delivery;

  int _qtyInCart(String id) {
    final found = _cart.where((e) => e.id == id).toList();
    return found.isEmpty ? 0 : found.first.qty;
  }

  void _add(Product p, {int qty = 1, bool silent = false}) {
    if (p.price == null) return;
    setState(() {
      final i = _cart.indexWhere((e) => e.id == p.id);
      if (i >= 0) {
        _cart[i].qty += qty;
      } else {
        _cart.add(CartItem(id: p.id, name: p.name, urdu: p.urdu, price: p.price!, image: p.image, qty: qty));
      }
    });
    _saveCart();
    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(trf('added_to_cart', {'product': p.displayName})), backgroundColor: kPrimary, duration: const Duration(seconds: 1)),
      );
    }
  }

  void _changeQty(String id, int delta) {
    setState(() {
      final i = _cart.indexWhere((e) => e.id == id);
      if (i < 0) return;
      _cart[i].qty += delta;
      if (_cart[i].qty <= 0) _cart.removeAt(i);
    });
    _saveCart();
  }

  void _removeFromCart(String id) {
    setState(() => _cart.removeWhere((e) => e.id == id));
    _saveCart();
  }

  void _toggleFav(String id) {
    setState(() {
      if (_favs.contains(id)) {
        _favs.remove(id);
      } else {
        _favs.add(id);
      }
    });
    _saveFavs();
  }

  void _openDetail(Product p) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => ProductDetailPage(
      product: p,
      allProducts: _products,
      qtyInCart: _qtyInCart,
      onAdd: _add,
      onChangeQty: _changeQty,
      isFav: _favs.contains(p.id),
      onToggleFav: () => _toggleFav(p.id),
      onProductUpdated: (updated) {
        setState(() {
          final i = _products.indexWhere((x) => x.id == updated.id);
          if (i >= 0) _products[i] = updated;
        });
        _saveProductsLocal();
      },
    )));
  }

  void _openListPage(String title, List<Product> products) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => ProductListPage(
      title: title,
      products: products,
      qtyInCart: _qtyInCart,
      onAdd: _add,
      onChangeQty: _changeQty,
      favs: _favs,
      onToggleFav: _toggleFav,
      onOpenDetail: _openDetail,
    )));
  }

  void _openCategory(String cat) {
    if (cat == 'Sab') {
      _openListPage(tr('all_products'), _products);
      return;
    }
    _openListPage(cat, _products.where((p) => p.category == cat).toList());
  }

  void _openSearch() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => SearchPage(
      products: _products,
      qtyInCart: _qtyInCart,
      onAdd: _add,
      onChangeQty: _changeQty,
      favs: _favs,
      onToggleFav: _toggleFav,
      onOpenDetail: _openDetail,
    )));
  }

  void _openCheckout() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => CheckoutPage(
      cart: List.of(_cart),
      subtotal: _subtotal,
      feeTable: _feeTable,
      hasFreeDelivery: _hasFreeDelivery,
      profileName: _profileName,
      profilePhone: _profilePhone,
      addresses: _addresses,
      onProfileSaved: (name, phone) {
        setState(() {
          _profileName = name;
          _profilePhone = phone;
        });
        _saveProfile();
      },
      onOrderPlaced: () {
        setState(() => _cart.clear());
        _saveCart();
      },
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Bin Umer Fabrics', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
          GestureDetector(
            onTap: () {
              _loadProducts();
              _loadBannersAndSettings();
            },
            child: Text(tr('header_subtitle'), style: TextStyle(fontSize: 12, color: Colors.white70)),
          ),
        ]),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: _openSearch),
          Stack(children: [
            IconButton(icon: const Icon(Icons.shopping_cart), onPressed: () => setState(() => _tab = 2)),
            if (_cartCount > 0)
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                  child: Text('$_cartCount', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
          ]),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [_homeTab(), _categoriesTab(), _cartTab(), _favsTab(), _accountTab()],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_cart.isNotEmpty && _tab != 2)
            InkWell(
              onTap: () => setState(() => _tab = 2),
              child: Container(
                color: kPrimaryDark,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  const Icon(Icons.shopping_cart, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(trf('cart_items', {'count': _cartCount}), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text(trf('cart_total', {'total': rs(_total)}), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Text(tr('view_cart'), style: TextStyle(color: Colors.white)),
                ]),
              ),
            ),
          BottomNavigationBar(
            currentIndex: _tab,
            selectedItemColor: kPrimary,
            unselectedItemColor: Colors.grey,
            type: BottomNavigationBarType.fixed,
            onTap: (i) => setState(() => _tab = i),
            items: [
              BottomNavigationBarItem(icon: Icon(Icons.home), label: tr('tab_home')),
              BottomNavigationBarItem(icon: Icon(Icons.grid_view), label: tr('tab_categories')),
              BottomNavigationBarItem(
                icon: Stack(children: [
                  const Icon(Icons.shopping_cart),
                  if (_cartCount > 0)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                        child: Text('$_cartCount', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                      ),
                    ),
                ]),
                label: tr('tab_cart'),
              ),
              BottomNavigationBarItem(icon: Icon(Icons.favorite), label: tr('tab_favourites')),
              BottomNavigationBarItem(icon: Icon(Icons.person), label: tr('tab_account')),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- Home ----------------
  Widget _homeTab() {
    final deals = _products.where((p) => p.freeDelivery).toList();
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          color: kPrimary,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: TextField(
            readOnly: true,
            onTap: _openSearch,
            decoration: InputDecoration(
              hintText: tr('search_hint_home'),
              prefixIcon: const Icon(Icons.search, color: kPrimary),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            ),
          ),
        ),
        if (_announcement.isNotEmpty)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF3E0),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Icon(Icons.campaign, color: kAccentDark, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(_announcement, style: const TextStyle(color: kAccentDark, fontWeight: FontWeight.bold, fontSize: 13))),
            ]),
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: 150,
          child: PageView.builder(
            controller: _bannerCtrl,
            onPageChanged: (i) => setState(() => _bannerIndex = i),
            itemCount: _banners.length,
            itemBuilder: (_, i) {
              final b = _banners[i];
              return InkWell(
                onTap: () => _openCategory(b.category),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(gradient: LinearGradient(colors: [b.from, b.to]), borderRadius: BorderRadius.circular(16)),
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(b.title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(b.subtitle, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                        child: Text(tr('shop_now'), style: TextStyle(color: b.from, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ])),
                    Text(b.emoji, style: const TextStyle(fontSize: 52)),
                  ]),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_banners.length, (i) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: _bannerIndex == i ? 18 : 8,
            height: 8,
            decoration: BoxDecoration(color: _bannerIndex == i ? kPrimary : Colors.grey.shade300, borderRadius: BorderRadius.circular(4)),
          )),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(tr('tab_categories'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 86,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: _chipCats.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (_, i) {
              final c = _chipCats[i];
              return InkWell(
                onTap: () => _openCategory(c),
                child: Column(children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: Icon(_iconFor(c), color: kPrimary, size: 28),
                  ),
                  const SizedBox(height: 6),
                  Text(c == 'Sab' ? tr('cat_all') : c, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ]),
              );
            },
          ),
        ),
        if (deals.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(tr('deals_today'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              TextButton(onPressed: () => _openListPage(tr('deals'), deals), child: Text(tr('see_all'))),
            ]),
          ),
          SizedBox(
            height: 226,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: deals.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => SizedBox(width: 150, child: _cardFor(deals[i])),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(tr('all_products'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.68),
            itemCount: _products.length,
            itemBuilder: (_, i) => _cardFor(_products[i]),
          ),
        ),
        const SizedBox(height: 16),
      ]),
      ),
    );
  }

  Widget _cardFor(Product p) => ProductCard(
        product: p,
        qty: _qtyInCart(p.id),
        isFav: _favs.contains(p.id),
        onTap: () => _openDetail(p),
        onAdd: () => _add(p, silent: true),
        onChangeQty: (d) => _changeQty(p.id, d),
        onToggleFav: () => _toggleFav(p.id),
      );

  // ---------------- Categories ----------------
  Widget _categoriesTab() {
    final cats = _categories.map((c) => c.name).toList();
    for (final p in _products) {
      if (!cats.contains(p.category)) cats.add(p.category);
    }
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView(padding: const EdgeInsets.all(16), physics: const AlwaysScrollableScrollPhysics(), children: [
      _categoryTile(tr('all_products'), _products.length, Icons.apps, null, () => _openListPage(tr('all_products'), _products)),
      const SizedBox(height: 10),
      _categoryTile(tr('deals'), _products.where((p) => p.freeDelivery).length, Icons.local_offer, null,
          () => _openListPage(tr('deals'), _products.where((p) => p.freeDelivery).toList())),
      const SizedBox(height: 10),
      ...cats.map((c) {
        final items = _products.where((p) => p.category == c).toList();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _categoryTile(c, items.length, _iconFor(c), items.isNotEmpty ? items.first : null, () => _openCategory(c)),
        );
      }),
      ]),
    );
  }

  Widget _categoryTile(String name, int count, IconData icon, Product? sample, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: const Color(0xFFE8EFE6), borderRadius: BorderRadius.circular(12)),
            child: sample == null
                ? Icon(icon, color: kPrimary, size: 28)
                : ClipRRect(borderRadius: BorderRadius.circular(12), child: productImageWidget(sample)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(trf('count_products', {'count': count}), style: const TextStyle(color: Colors.grey)),
          ])),
          const Icon(Icons.chevron_right, color: Colors.grey),
        ]),
      ),
    );
  }

  // ---------------- Cart (proper cart page) ----------------
  Widget _cartTab() {
    if (_cart.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.shopping_cart_outlined, size: 64, color: Colors.grey),
        const SizedBox(height: 10),
        Text(tr('cart_empty'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(tr('cart_empty_hint')),
        const SizedBox(height: 14),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white), onPressed: () => setState(() => _tab = 0), child: Text(tr('start_shopping'))),
      ]));
    }
    final hasFree = _delivery == 0;
    return Column(children: [
      Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: hasFree ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(hasFree ? Icons.check_circle : Icons.local_shipping, color: hasFree ? kPrimary : kAccentDark),
          const SizedBox(width: 8),
          Expanded(child: Text(
            hasFree ? tr('free_delivery_congrats') : tr('free_delivery_hint'),
            style: TextStyle(fontWeight: FontWeight.bold, color: hasFree ? kPrimary : kAccentDark, fontSize: 13),
          )),
        ]),
      ),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: _cart.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            final it = _cart[i];
            final prod = Product(id: it.id, name: it.name, image: it.image);
            return Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(width: 64, height: 64, child: productImageWidget(prod)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(it.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(rs(it.price), style: const TextStyle(color: kPrimaryDark, fontSize: 13)),
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      InkWell(onTap: () => _changeQty(it.id, -1), child: const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4), child: Icon(Icons.remove, size: 18))),
                      Text('${it.qty}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      InkWell(onTap: () => _changeQty(it.id, 1), child: const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4), child: Icon(Icons.add, size: 18))),
                    ]),
                  ),
                ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  InkWell(onTap: () => _removeFromCart(it.id), child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.delete_outline, color: Colors.red, size: 20))),
                  const SizedBox(height: 8),
                  Text(rs(it.price * it.qty), style: const TextStyle(fontWeight: FontWeight.bold)),
                ]),
              ]),
            );
          },
        ),
      ),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        child: Column(children: [
          _row(tr('subtotal'), rs(_subtotal)),
          _row(tr('delivery'), _delivery == 0 ? tr('free') : rs(_delivery)),
          if (hasFree) _row(tr('you_saved'), rs(_feeTable['fee_near_normal'] ?? 100), green: true),
          const Divider(),
          _row(tr('total'), rs(_total), bold: true),
          const SizedBox(height: 6),
          Row(children: [
            TextButton(onPressed: () { setState(() => _cart.clear()); _saveCart(); }, child: Text(tr('clear_cart'))),
            const Spacer(),
            Text(tr('cod'), style: TextStyle(color: Colors.grey, fontSize: 12)),
          ]),
          const SizedBox(height: 6),
          SizedBox(width: double.infinity, child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: _openCheckout,
            child: Text(tr('checkout_btn'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          )),
        ]),
      ),
    ]);
  }

  Widget _row(String k, String v, {bool bold = false, bool green = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(k, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, color: green ? kPrimary : null)),
      Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, color: green ? kPrimary : null)),
    ]),
  );

  // ---------------- Favourites ----------------
  Widget _favsTab() {
    final favProducts = _products.where((p) => _favs.contains(p.id)).toList();
    if (favProducts.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.favorite_border, size: 64, color: Colors.grey),
        const SizedBox(height: 10),
        Text(tr('no_favourites'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(tr('no_favourites_hint')),
      ]));
    }
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.68),
        itemCount: favProducts.length,
        itemBuilder: (_, i) => _cardFor(favProducts[i]),
      ),
    );
  }

  // ---------------- Account ----------------
  Widget _accountTab() {
    final initial = _profileName.isNotEmpty ? _profileName[0].toUpperCase() : '?';
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView(padding: const EdgeInsets.all(16), physics: const AlwaysScrollableScrollPhysics(), children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: kPrimary, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          CircleAvatar(radius: 28, backgroundColor: Colors.white, child: Text(initial, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: kPrimary))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_profileName.isNotEmpty ? _profileName : tr('guest'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            Text(_profilePhone.isNotEmpty ? _profilePhone : tr('save_phone'), style: const TextStyle(color: Colors.white70)),
          ])),
          TextButton(
            onPressed: _editProfile,
            child: Text(tr('edit'), style: TextStyle(color: Colors.white)),
          ),
        ]),
      ),
      const SizedBox(height: 16),

      _accountTile(Icons.receipt_long, tr('my_orders'), tr('my_orders_sub'), () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const MyOrdersPage()));
      }),
      _accountTile(Icons.location_on, tr('my_addresses'), tr('my_addresses_sub'), () async {
        final updated = await Navigator.push<List<Map<String, String>>>(context, MaterialPageRoute(builder: (_) => AddressesPage(addresses: List.of(_addresses))));
        if (updated != null) {
          setState(() => _addresses = updated);
          _saveAddresses();
        }
      }),
      _accountTile(Icons.favorite, tr('fav_products'), trf('count_products', {'count': _favs.length}), () => setState(() => _tab = 3)),
      _accountTile(Icons.language, tr('language'), appLang == 'ur' ? 'اردو' : appLang == 'roman' ? 'Roman Urdu' : 'English', _showLanguageDialog),
      _accountTile(Icons.logout, tr('logout_title'), tr('logout_sub'), _logout),
      const Divider(height: 28),
      _accountTile(Icons.store, tr('store_address'), kShopAddress, () {}),
      const SizedBox(height: 16),
      GestureDetector(
        onTap: _onVersionTap,
        child: const Text('Version 1.0.0 • Bin Umer Fabrics • Offline (Frontend Preview)', style: TextStyle(color: Colors.grey), textAlign: TextAlign.center),
      ),
      ]),
    );
  }

  Widget _accountTile(IconData icon, String title, String subtitle, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: ListTile(leading: Icon(icon, color: kPrimary), title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text(subtitle), trailing: const Icon(Icons.chevron_right, color: Colors.grey), onTap: onTap),
    );
  }

  void _editProfile() {
    final nameCtrl = TextEditingController(text: _profileName);
    final phoneCtrl = TextEditingController(text: _profilePhone);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('your_details')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('name_label'))),
          TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: tr('mobile_number'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('back'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white),
            onPressed: () {
              setState(() {
                _profileName = nameCtrl.text.trim();
                _profilePhone = phoneCtrl.text.trim();
              });
              _saveProfile();
              Navigator.pop(ctx);
            },
            child: Text(tr('save')),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('logout_title')),
        content: Text(tr('logout_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('logout_confirm'))),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('profile_phone');
    await prefs.remove('profile_name');
    setState(() {
      _profileName = '';
      _profilePhone = '';
    });
    if (mounted) setState(() {});
  }

  void _showLanguageDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('choose_language')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          RadioListTile<String>(
            value: 'en',
            groupValue: appLang,
            onChanged: (v) => _setLanguage(v ?? 'en'),
            title: Text(tr('lang_english')),
          ),
          RadioListTile<String>(
            value: 'ur',
            groupValue: appLang,
            onChanged: (v) => _setLanguage(v ?? 'ur'),
            title: Text(tr('lang_urdu')),
          ),
          RadioListTile<String>(
            value: 'roman',
            groupValue: appLang,
            onChanged: (v) => _setLanguage(v ?? 'roman'),
            title: Text(tr('lang_roman')),
          ),
        ]),
      ),
    );
  }

  Future<void> _setLanguage(String lang) async {
    Navigator.pop(context);
    if (lang == appLang) return;
    appLang = lang;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLangPrefKey, lang);
    if (mounted) setState(() {});
  }

  void _onVersionTap() {
    final now = DateTime.now();
    if (_lastVersionTap == null || now.difference(_lastVersionTap!).inSeconds > 2) {
      _versionTaps = 1;
    } else {
      _versionTaps++;
    }
    _lastVersionTap = now;
    if (_versionTaps >= 5) {
      _versionTaps = 0;
      _lastVersionTap = null;
      _askAdminPin();
    }
  }

  void _askAdminPin() {
    final pinCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('admin_pin')),
        content: TextField(controller: pinCtrl, keyboardType: TextInputType.number, obscureText: true, decoration: InputDecoration(labelText: tr('enter_pin'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('back'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white),
            onPressed: () async {
              if (pinCtrl.text.trim() != kAdminPin) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('wrong_pin'))));
                return;
              }
              Navigator.pop(ctx);
              final updated = await Navigator.push<List<Product>>(context, MaterialPageRoute(builder: (_) => _AdminHomePage(
                    products: List.of(_products),
                    categories: List.of(_categories),
                    onCategoriesChanged: (cats) {
                      setState(() => _categories = cats);
                      _saveCategoriesCache();
                    },
                  )));
              if (updated != null && updated.isNotEmpty) {
                setState(() => _products = updated);
                _saveProductsLocal();
                _loadProducts();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('products_saved')), backgroundColor: kPrimary));
              }
            },
            child: Text(tr('open')),
          ),
        ],
      ),
    );
  }
}

class _TrustChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TrustChip({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [Icon(icon, color: kPrimary, size: 22), const SizedBox(height: 4), Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))]),
    );
  }
}

// ---------------- Shared product card ----------------
class ProductCard extends StatelessWidget {
  final Product product;
  final int qty;
  final bool isFav;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final void Function(int delta) onChangeQty;
  final VoidCallback onToggleFav;
  const ProductCard({
    super.key,
    required this.product,
    required this.qty,
    required this.isFav,
    required this.onTap,
    required this.onAdd,
    required this.onChangeQty,
    required this.onToggleFav,
  });

  @override
  Widget build(BuildContext context) {
    final p = product;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 3))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Stack(children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                child: productImageWidget(p),
              ),
              if (p.freeDelivery)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(10)),
                    child: Text(tr('free_delivery'), style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
              Positioned(
                right: 6,
                top: 6,
                child: InkWell(
                  onTap: onToggleFav,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: Icon(isFav ? Icons.favorite : Icons.favorite_border, color: isFav ? Colors.red : Colors.grey, size: 18),
                  ),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              Text(rs(p.price ?? 0), style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimaryDark, fontSize: 14)),
              if (p.ratingCount > 0) ...[
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.star, size: 14, color: Colors.amber[700]),
                  Text(' ${p.averageRating.toStringAsFixed(1)} (${p.ratingCount})', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ]),
              ],
              const SizedBox(height: 6),
              if (qty == 0)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white, padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    onPressed: onAdd,
                    child: Text(tr('add_btn'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(color: kPrimary, borderRadius: BorderRadius.circular(8)),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    InkWell(onTap: () => onChangeQty(-1), child: const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Icon(Icons.remove, color: Colors.white, size: 18))),
                    Text('$qty', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    InkWell(onTap: () => onChangeQty(1), child: const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Icon(Icons.add, color: Colors.white, size: 18))),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------- Product detail (full page) ----------------
class ProductDetailPage extends StatefulWidget {
  final Product product;
  final List<Product> allProducts;
  final int Function(String) qtyInCart;
  final void Function(Product, {int qty, bool silent}) onAdd;
  final void Function(String, int) onChangeQty;
  final bool isFav;
  final VoidCallback onToggleFav;
  final void Function(Product)? onProductUpdated;
  const ProductDetailPage({
    super.key,
    required this.product,
    required this.allProducts,
    required this.qtyInCart,
    required this.onAdd,
    required this.onChangeQty,
    required this.isFav,
    required this.onToggleFav,
    this.onProductUpdated,
  });
  @override
  State<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends State<ProductDetailPage> {
  int _qty = 1;
  late bool _fav;
  late Product _p;

  @override
  void initState() {
    super.initState();
    _fav = widget.isFav;
    _p = widget.product;
  }

  void _showReviewDialog() {
    int stars = 5;
    final nameCtrl = TextEditingController();
    final commentCtrl = TextEditingController();
    bool busy = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx2, setD) {
        return AlertDialog(
          title: Text(tr('write_review')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    onPressed: () => setD(() => stars = i),
                    icon: Icon(i <= stars ? Icons.star : Icons.star_border, color: Colors.amber[700], size: 32),
                  ),
              ]),
              TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('review_name'))),
              const SizedBox(height: 10),
              TextField(controller: commentCtrl, maxLines: 3, decoration: InputDecoration(labelText: tr('review_comment'), border: OutlineInputBorder())),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('back'))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white),
              onPressed: busy
                  ? null
                  : () async {
                      setD(() => busy = true);
                      try {
                        final name = nameCtrl.text.trim().isEmpty ? tr('customer_default') : nameCtrl.text.trim();
                        await submitProductReview(_p.id, name: name, rating: stars, comment: commentCtrl.text.trim());
                        final Map<String, dynamic> newReview = {'name': name, 'rating': stars, 'comment': commentCtrl.text.trim(), 'created_ms': DateTime.now().millisecondsSinceEpoch};
                        if (mounted) {
                          setState(() => _p = _p.copyWith(
                                ratingSum: _p.ratingSum + stars,
                                ratingCount: _p.ratingCount + 1,
                                reviews: [..._p.reviews, newReview],
                              ));
                          // Main list + local cache bhi foran update — taa ke app band kar ke
                          // dobara kholne par review turant dikhe, fetch ka intezar na ho.
                          widget.onProductUpdated?.call(_p);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('review_saved')), backgroundColor: kPrimary));
                      } catch (_) {
                        setD(() => busy = false);
                        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(tr('review_failed'))));
                      }
                    },
              child: Text(tr('submit_review')),
            ),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final related = widget.allProducts.where((x) => x.category == p.category && x.id != p.id).take(6).toList();
    final inCart = widget.qtyInCart(p.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(_fav ? Icons.favorite : Icons.favorite_border, color: Colors.white),
            onPressed: () {
              setState(() => _fav = !_fav);
              widget.onToggleFav();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            SizedBox(height: 300, width: double.infinity, child: productImageWidget(p)),
            if (p.freeDelivery)
              Positioned(
                left: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(12)),
                  child: Text(tr('free_delivery'), style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              if (p.urdu.isNotEmpty) Text(p.urdu, style: const TextStyle(fontSize: 18, color: Colors.black54)),
              const SizedBox(height: 8),
              Text(rs(p.price ?? 0), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kPrimary)),
              Text(p.category, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              Text(p.desc.isEmpty ? tr('guarantee') : p.desc, style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 12),
              Row(children: [
                _TrustChip(icon: Icons.payments, label: tr('cod')),
                SizedBox(width: 8),
                Expanded(child: _TrustChip(icon: Icons.verified, label: tr('pure_100'))),
                SizedBox(width: 8),
                Expanded(child: _TrustChip(icon: Icons.local_shipping, label: tr('all_pakistan'))),
              ]),
              const SizedBox(height: 20),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Row(children: [
                  Text(tr('reviews'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  if (p.ratingCount > 0) ...[
                    starRow(p.averageRating, size: 18),
                    const SizedBox(width: 6),
                    Text('${p.averageRating.toStringAsFixed(1)} (${p.ratingCount})', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ]),
                children: [
                  if (p.ratingCount > 0)
                    ...p.reviews.reversed.map((r) => Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text('${r['name'] ?? tr('customer_default')}', style: const TextStyle(fontWeight: FontWeight.bold))),
                              Text(reviewDateText(r['created_ms']), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                            ]),
                            const SizedBox(height: 4),
                            starRow(((r['rating'] as num?)?.toDouble() ?? 5).toDouble(), size: 14),
                            if (('${r['comment'] ?? ''}').isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('${r['comment']}'),
                            ],
                          ]),
                        )),
                  if (p.ratingCount == 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(tr('no_reviews')),
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: _showReviewDialog, child: Text(tr('write_review'))),
                  ),
                ],
              ),
              if (related.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(tr('similar_products'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                SizedBox(
                  height: 226,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: related.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (_, i) {
                      final r = related[i];
                      return SizedBox(
                        width: 150,
                        child: ProductCard(
                          product: r,
                          qty: widget.qtyInCart(r.id),
                          isFav: false,
                          onTap: () {
                            Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ProductDetailPage(
                              product: r,
                              allProducts: widget.allProducts,
                              qtyInCart: widget.qtyInCart,
                              onAdd: widget.onAdd,
                              onChangeQty: widget.onChangeQty,
                              isFav: false,
                              onToggleFav: () {},
                              onProductUpdated: widget.onProductUpdated,
                            )));
                          },
                          onAdd: () => widget.onAdd(r, silent: true),
                          onChangeQty: (d) => widget.onChangeQty(r.id, d),
                          onToggleFav: () {},
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 90),
            ]),
          ),
        ]),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(14),
        decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))]),
        child: Row(children: [
          Container(
            decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              IconButton(onPressed: () => setState(() { if (_qty > 1) _qty--; }), icon: const Icon(Icons.remove)),
              Text('$_qty', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: () {
                widget.onAdd(p, qty: _qty);
                Navigator.pop(context);
              },
              child: Text(inCart > 0
                  ? trf('update_cart_btn', {'total': rs((p.price ?? 0) * _qty)})
                  : trf('add_to_cart_btn', {'total': rs((p.price ?? 0) * _qty)})),
            ),
          ),
        ]),
      ),
    );
  }
}

// ---------------- Product list page (category / deals) ----------------
class ProductListPage extends StatelessWidget {
  final String title;
  final List<Product> products;
  final int Function(String) qtyInCart;
  final void Function(Product, {int qty, bool silent}) onAdd;
  final void Function(String, int) onChangeQty;
  final Set<String> favs;
  final void Function(String) onToggleFav;
  final void Function(Product) onOpenDetail;
  const ProductListPage({
    super.key,
    required this.title,
    required this.products,
    required this.qtyInCart,
    required this.onAdd,
    required this.onChangeQty,
    required this.favs,
    required this.onToggleFav,
    required this.onOpenDetail,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: products.isEmpty
          ? Center(child: Text(tr('no_products_here')))
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.68),
              itemCount: products.length,
              itemBuilder: (_, i) {
                final p = products[i];
                return ProductCard(
                  product: p,
                  qty: qtyInCart(p.id),
                  isFav: favs.contains(p.id),
                  onTap: () => onOpenDetail(p),
                  onAdd: () => onAdd(p, silent: true),
                  onChangeQty: (d) => onChangeQty(p.id, d),
                  onToggleFav: () => onToggleFav(p.id),
                );
              },
            ),
    );
  }
}

// ---------------- Search page ----------------
class SearchPage extends StatefulWidget {
  final List<Product> products;
  final int Function(String) qtyInCart;
  final void Function(Product, {int qty, bool silent}) onAdd;
  final void Function(String, int) onChangeQty;
  final Set<String> favs;
  final void Function(String) onToggleFav;
  final void Function(Product) onOpenDetail;
  const SearchPage({
    super.key,
    required this.products,
    required this.qtyInCart,
    required this.onAdd,
    required this.onChangeQty,
    required this.favs,
    required this.onToggleFav,
    required this.onOpenDetail,
  });
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String _query = '';
  List<String> _recent = [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _recent = prefs.getStringList('recent_searches') ?? []);
  }

  Future<void> _saveRecent(String q) async {
    final prefs = await SharedPreferences.getInstance();
    final list = [q, ..._recent.where((e) => e != q)].take(8).toList();
    await prefs.setStringList('recent_searches', list);
    if (mounted) setState(() => _recent = list);
  }

  List<Product> get _results {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return [];
    return widget.products.where((p) =>
        p.name.toLowerCase().contains(q) || p.urdu.contains(_query.trim()) || p.desc.toLowerCase().contains(q) || p.category.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(hintText: tr('search_products'), hintStyle: TextStyle(color: Colors.white70), border: InputBorder.none),
          onChanged: (v) => setState(() => _query = v),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) _saveRecent(v.trim());
          },
        ),
      ),
      body: _query.trim().isEmpty
          ? ListView(padding: const EdgeInsets.all(16), children: [
              if (_recent.isNotEmpty) ...[
                Text(tr('recent_searches'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: _recent.map((r) => ActionChip(label: Text(r), onPressed: () => setState(() => _query = r))).toList(),
                ),
                const SizedBox(height: 16),
              ],
              Text(tr('popular_searches'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: ['Wash & Wear', 'Boski', 'Cotton', 'Lawn', 'Khaddar', 'Karandi']
                    .map((r) => ActionChip(label: Text(r), onPressed: () => setState(() => _query = r)))
                    .toList(),
              ),
            ])
          : results.isEmpty
              ? Center(child: Text(tr('nothing_found')))
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.68),
                  itemCount: results.length,
                  itemBuilder: (_, i) {
                    final p = results[i];
                    return ProductCard(
                      product: p,
                      qty: widget.qtyInCart(p.id),
                      isFav: widget.favs.contains(p.id),
                      onTap: () => widget.onOpenDetail(p),
                      onAdd: () => widget.onAdd(p, silent: true),
                      onChangeQty: (d) => widget.onChangeQty(p.id, d),
                      onToggleFav: () => widget.onToggleFav(p.id),
                    );
                  },
                ),
    );
  }
}

// ---------------- Checkout page ----------------
class CheckoutPage extends StatefulWidget {
  final List<CartItem> cart;
  final int subtotal;
  final Map<String, int> feeTable;
  final bool hasFreeDelivery;
  final String profileName;
  final String profilePhone;
  final List<Map<String, String>> addresses;
  final void Function(String name, String phone) onProfileSaved;
  final VoidCallback onOrderPlaced;
  const CheckoutPage({
    super.key,
    required this.cart,
    required this.subtotal,
    required this.feeTable,
    required this.hasFreeDelivery,
    required this.profileName,
    required this.profilePhone,
    required this.addresses,
    required this.onProfileSaved,
    required this.onOrderPlaced,
  });
  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _addrCtrl;
  late TextEditingController _cityCtrl;
  int _selectedAddress = -1;
  int _speedIdx = 0;
  int _areaIdx = 0;
  bool _placing = false;
  bool _calculatingDistance = false;
  bool _distanceReady = false;
  bool _outsideCity = false;
  Timer? _debounce;
  String? _distanceNote;

  int get _delivery => deliveryFeeFor(widget.feeTable, _areaIdx, _speedIdx, widget.hasFreeDelivery);
  int get _discount => 0;
  int get _total => widget.subtotal - _discount + _delivery;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.profileName);
    _phoneCtrl = TextEditingController(text: widget.profilePhone);
    _addrCtrl = TextEditingController();
    _cityCtrl = TextEditingController();
    _addrCtrl.addListener(_onAddressChanged);
    _cityCtrl.addListener(_onAddressChanged);
    if (widget.addresses.isNotEmpty) _useAddress(0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _calculateDistance());
  }

  /// Pata likhte hi fasla khud calculate ho — button dabane ki zaroorat nahi.
  /// Har harf par request na jaye, is liye 900ms ruk kar aik dafa chalao.
  void _onAddressChanged() {
    _debounce?.cancel();
    final addr = _addrCtrl.text.trim();
    final city = _cityCtrl.text.trim();
    if (addr.length < 4 || city.isEmpty) {
      if (_distanceReady || _distanceNote != null) {
        setState(() {
          _distanceReady = false;
          _outsideCity = false;
          _distanceNote = null;
        });
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 900), _calculateDistance);
  }

  /// Waqt ko 12 ghante wali shakal mein dikhao (masalan 9:00 PM).
  String _fmtTime(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  /// Har speed par delivery kab pohunchegi.
  /// Raat 10 bajay ke baad se subah 8 bajay tak ke TAMAAM orders subah 10 se 12
  /// bajay ke darmiyan deliver hote hain. Raat 8 bajay ke baad Normal order
  /// aglay din subah 12 bajay tak milta hai; Urgent 1 ghante mein — raat 8 bajay
  /// ka order raat 9 bajay tak.
  String _expectedText(int speedIdx) {
    if (_outsideCity) return tr('outside_delivery_time');
    final now = DateTime.now();
    if (now.hour >= 22) return tr('morning_window_tomorrow');
    if (now.hour < 8) return tr('morning_window_today');
    if (speedIdx == 0) {
      if (now.hour >= 20) return tr('tomorrow_noon');
      final target = now.add(const Duration(hours: 6));
      if (target.hour >= 22 || target.day != now.day) return tr('morning_window_tomorrow');
      return trf('expected_about', {'time': _fmtTime(target)});
    }
    final target = now.add(Duration(hours: speedIdx == 1 ? 4 : 1));
    if (target.hour >= 22 || target.day != now.day) return tr('morning_window_tomorrow');
    return trf('expected_today', {'time': _fmtTime(target)});
  }

  /// Address se fasla khud nikalo — customer ko area chunne ki zaroorat nahi.
  /// Sheher Multan na ho to seedha 'City se bahir' (Rs 299) — koi geocode nahi.
  /// Pata na mile to pehle sheher ki satah par koshish karo (Multan ka markaz
  /// dukaan ke qareeb hai); phir bhi na mile to area wala hissa backup ke tor
  /// par dikhao. Options sirf fasla tay hone ke baad dikhte hain.
  /// Delivery offline: sheher Multan ho to Qareeb (flat fee), warna 'City se bahir' (Rs 299).
  Future<void> _calculateDistance() async {
    final addr = _addrCtrl.text.trim();
    final cityRaw = _cityCtrl.text.trim();
    if (addr.length < 4 || cityRaw.isEmpty) return;
    final city = cityRaw.toLowerCase();
    if (!city.contains('multan') && !city.contains('ملتان')) {
      setState(() {
        _areaIdx = 3;
        _distanceReady = true;
        _outsideCity = true;
        _distanceNote = null;
      });
      return;
    }
    setState(() {
      _areaIdx = 0;
      _distanceReady = true;
      _outsideCity = false;
      _distanceNote = null;
    });
  }

  void _useAddress(int i) {
    setState(() {
      _selectedAddress = i;
      _addrCtrl.text = widget.addresses[i]['address'] ?? '';
      _cityCtrl.text = widget.addresses[i]['city'] ?? '';
    });
    Future.microtask(_calculateDistance);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addrCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _placeOrder() async {
    if (_nameCtrl.text.trim().isEmpty || _phoneCtrl.text.trim().isEmpty || _addrCtrl.text.trim().isEmpty || _cityCtrl.text.trim().isEmpty || !_distanceReady) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('fill_all'))));
      return;
    }
    setState(() => _placing = true);
    final items = widget.cart.map((e) => {'name': e.name, 'price': e.price, 'qty': e.qty}).toList();
    String? orderId;
    bool savedOnline = false;
    try {
      orderId = await insertOrder(
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        address: _addrCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
        items: items,
        subtotal: widget.subtotal,
        delivery: _delivery,
        total: _total,
        deliverySpeed: kDeliverySpeeds[_speedIdx],
        deliveryArea: kDeliveryAreas[_areaIdx],
      );
      savedOnline = true;
    } catch (_) {
      savedOnline = false;
    }
    if (!savedOnline) {
      if (mounted) {
        setState(() => _placing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('order_failed'))));
      }
      return;
    }
    widget.onProfileSaved(_nameCtrl.text.trim(), _phoneCtrl.text.trim());
    widget.onOrderPlaced();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => OrderConfirmationPage(orderId: orderId, total: _total, deliveryInfo: _outsideCity ? tr('outside_delivery_time') : '${speedLabel(_speedIdx)} — ${_expectedText(_speedIdx)}', name: _nameCtrl.text.trim(), savedOnline: savedOnline)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('checkout'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('delivery_address'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (widget.addresses.isNotEmpty)
            ...widget.addresses.asMap().entries.map((e) => RadioListTile<int>(
                  value: e.key,
                  groupValue: _selectedAddress,
                  onChanged: (v) => _useAddress(v ?? 0),
                  title: Text(e.value['label'] ?? tr('address_label')),
                  subtitle: Text('${e.value['address']}, ${e.value['city']}'),
                )),
          TextField(controller: _nameCtrl, decoration: InputDecoration(labelText: tr('your_name'), filled: true, fillColor: Colors.white)),
          const SizedBox(height: 8),
          TextField(controller: _phoneCtrl, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: tr('mobile_number_req'), filled: true, fillColor: Colors.white)),
          const SizedBox(height: 8),
          TextField(controller: _addrCtrl, decoration: InputDecoration(labelText: tr('full_address'), filled: true, fillColor: Colors.white)),
          const SizedBox(height: 8),
          TextField(controller: _cityCtrl, decoration: InputDecoration(labelText: tr('city_req'), filled: true, fillColor: Colors.white)),
          const SizedBox(height: 8),
          if (_calculatingDistance) const LinearProgressIndicator(),
          if (_calculatingDistance) ...[
            const SizedBox(height: 6),
            Text(tr('calculating_distance'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
          if (_distanceNote != null) Text(_distanceNote!, style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimary)),
          if (!_distanceReady && !_calculatingDistance && _distanceNote == null)
            Text(tr('enter_address_hint'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          if (_distanceReady) ...[
            const SizedBox(height: 16),
            if (_outsideCity)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kPrimary)),
                child: Row(children: [
                  Icon(Icons.check_circle, color: kPrimary),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(trf('outside_option_title', {'fee': rs(widget.feeTable['fee_outside'] ?? 299)}), style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(tr('outside_option_sub'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  ])),
                ]),
              )
            else ...[
              Text(tr('delivery_speed'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...List.generate(kDeliverySpeeds.length, (i) => RadioListTile<int>(
                    value: i,
                    groupValue: _speedIdx,
                    onChanged: (v) => setState(() => _speedIdx = v ?? 0),
                    title: Text(speedLabel(i)),
                    subtitle: Text('${hintLabel(i)} • ${_expectedText(i)} • ${deliveryFeeFor(widget.feeTable, _areaIdx, i, widget.hasFreeDelivery) == 0 ? tr('free') : rs(deliveryFeeFor(widget.feeTable, _areaIdx, i, widget.hasFreeDelivery))}'),
                  )),
            ],
          ],
          if (_distanceReady) ...[
          const SizedBox(height: 16),
          Text(tr('payment'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.payments, color: kPrimary),
              SizedBox(width: 10),
              Expanded(child: Text(tr('cod'), style: TextStyle(fontWeight: FontWeight.bold))),
              Icon(Icons.check_circle, color: kPrimary),
            ]),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              _sumRow(tr('subtotal'), rs(widget.subtotal)),
              _sumRow(_outsideCity ? tr('delivery') : trf('delivery_speed_x', {'speed': speedLabel(_speedIdx)}), _delivery == 0 ? tr('free') : rs(_delivery)),
              const Divider(),
              _sumRow(tr('total'), rs(_total), bold: true),
            ]),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _placing ? null : _placeOrder,
              child: Text(_placing ? tr('placing_order') : trf('confirm_order_btn', {'total': rs(_total)}), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 8),
          Text(tr('order_placed_contact'), style: TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center),
          ],
        ]),
      ),
    );
  }

  Widget _sumRow(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );
}

// ---------------- Order confirmation ----------------
class OrderConfirmationPage extends StatelessWidget {
  final String? orderId;
  final int total;
  final String deliveryInfo;
  final String name;
  final bool savedOnline;
  const OrderConfirmationPage({super.key, required this.orderId, required this.total, required this.deliveryInfo, required this.name, required this.savedOnline});

  @override
  Widget build(BuildContext context) {
    final shortId = orderId != null && orderId!.length >= 8 ? orderId!.substring(0, 8).toUpperCase() : null;
    return Scaffold(
      appBar: AppBar(title: Text(tr('order_placed_title')), automaticallyImplyLeading: false),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(color: Color(0xFFE8F5E9), shape: BoxShape.circle),
            child: const Icon(Icons.check, color: kPrimary, size: 56),
          ),
          const SizedBox(height: 20),
          Text(tr('order_received'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(trf('greeting_confirm', {'name': name}), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              if (shortId != null) _cRow(tr('order_no'), shortId),
              _cRow(tr('total'), trf('cod_total', {'total': rs(total)})),
              _cRow(tr('delivery'), deliveryInfo),
              _cRow(tr('status'), tr('placed')),
            ]),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MyOrdersPage())),
              child: Text(tr('view_my_orders')),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Navigator.popUntil(context, (r) => r.isFirst), child: Text(tr('continue_shopping'))),
        ]),
      ),
    );
  }

  Widget _cRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(k), Text(v, style: const TextStyle(fontWeight: FontWeight.bold))]),
      );
}

// ---------------- My Orders (customer) ----------------
class MyOrdersPage extends StatefulWidget {
  const MyOrdersPage({super.key});
  @override
  State<MyOrdersPage> createState() => _MyOrdersPageState();
}

class _MyOrdersPageState extends State<MyOrdersPage> {
  List<FabricOrder> _orders = [];
  bool _loading = true;
  String? _error;
  String _phone = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _phone = prefs.getString('profile_phone') ?? '';
    if (_phone.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _load();
  }

  String _norm(String p) {
    final digits = p.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final all = await fetchRemoteOrders();
      final mine = all.where((o) => _norm(o.phone) == _norm(_phone)).toList();
      if (mounted) setState(() => _orders = mine);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'Naya':
        return kAccentDark;
      case 'Confirm':
        return kPrimary;
      case 'Tayyar':
        return Colors.purple;
      case 'Delivered':
        return kPrimary;
      default:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('my_orders'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _phone.isEmpty
              ? _phonePrompt()
              : _error != null
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(tr('orders_load_failed')),
                      const SizedBox(height: 12),
                      ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white), onPressed: _load, child: Text(tr('try_again'))),
                    ]))
                  : _orders.isEmpty
                      ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.receipt_long, size: 64, color: Colors.grey),
                          const SizedBox(height: 10),
                          Text(tr('no_orders_yet'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Text(trf('order_not_found', {'phone': _phone})),
                        ]))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.all(14),
                            itemCount: _orders.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (_, i) {
                              final o = _orders[i];
                              return Container(
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                                child: ExpansionTile(
                                  title: Text(trf('order_label', {'id': o.id.length >= 8 ? o.id.substring(0, 8).toUpperCase() : o.id}), style: const TextStyle(fontWeight: FontWeight.bold)),
                                  subtitle: Text('${rs(o.total)} • ${o.dateText}'),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(color: _statusColor(o.status).withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
                                    child: Text(statusLabel(o.status), style: TextStyle(color: _statusColor(o.status), fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        ...o.items.map((it) => Padding(
                                              padding: const EdgeInsets.symmetric(vertical: 2),
                                              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                                Expanded(child: Text('${it['name']} x${it['qty']}')),
                                                Text(rs((it['price'] as num).toInt() * (it['qty'] as num).toInt())),
                                              ]),
                                            )),
                                        const Divider(),
                                        Text(trf('order_total_line', {'total': rs(o.total)}), style: const TextStyle(fontWeight: FontWeight.bold)),
                                        Text(trf('address_line', {'address': o.address, 'city': o.city})),
                                      ]),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
    );
  }

  Widget _phonePrompt() {
    final ctrl = TextEditingController();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.phone_android, size: 56, color: Colors.grey),
        const SizedBox(height: 12),
        Text(tr('orders_phone_hint'), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        TextField(controller: ctrl, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: tr('mobile_number'), filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white),
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('profile_phone', ctrl.text.trim());
              setState(() => _phone = ctrl.text.trim());
              _load();
            },
            child: Text(tr('view_orders')),
          ),
        ),
      ]),
    );
  }
}

// ---------------- Addresses ----------------
class AddressesPage extends StatefulWidget {
  final List<Map<String, String>> addresses;
  const AddressesPage({super.key, required this.addresses});
  @override
  State<AddressesPage> createState() => _AddressesPageState();
}

class _AddressesPageState extends State<AddressesPage> {
  late List<Map<String, String>> _list;

  @override
  void initState() {
    super.initState();
    _list = widget.addresses;
  }

  void _edit([int? index]) {
    final old = index == null ? null : _list[index];
    final labelCtrl = TextEditingController(text: old?['label'] ?? '');
    final addrCtrl = TextEditingController(text: old?['address'] ?? '');
    final cityCtrl = TextEditingController(text: old?['city'] ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(old == null ? tr('new_address') : tr('edit_address')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: labelCtrl, decoration: InputDecoration(labelText: tr('address_name'))),
          TextField(controller: addrCtrl, decoration: InputDecoration(labelText: tr('full_address'))),
          TextField(controller: cityCtrl, decoration: InputDecoration(labelText: tr('city_req'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('back'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white),
            onPressed: () {
              if (addrCtrl.text.trim().isEmpty || cityCtrl.text.trim().isEmpty) return;
              final entry = {'label': labelCtrl.text.trim().isEmpty ? tr('address_label') : labelCtrl.text.trim(), 'address': addrCtrl.text.trim(), 'city': cityCtrl.text.trim()};
              setState(() {
                if (index == null) {
                  _list.add(entry);
                } else {
                  _list[index] = entry;
                }
              });
              Navigator.pop(ctx);
            },
            child: Text(tr('save')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('my_addresses')),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context, _list)),
      ),
      body: _list.isEmpty
          ? Center(child: Text(tr('no_address_saved')))
          : ListView.separated(
              padding: const EdgeInsets.all(14),
              itemCount: _list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final a = _list[i];
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    const Icon(Icons.location_on, color: kPrimary),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a['label'] ?? tr('address_label'), style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('${a['address']}, ${a['city']}'),
                      if (i == 0) Text(tr('default_address'), style: TextStyle(color: kPrimary, fontSize: 12, fontWeight: FontWeight.bold)),
                    ])),
                    if (i != 0)
                      IconButton(
                        icon: const Icon(Icons.star_border, color: kAccentDark),
                        tooltip: tr('make_default'),
                        onPressed: () => setState(() {
                          final e = _list.removeAt(i);
                          _list.insert(0, e);
                        }),
                      ),
                    IconButton(icon: const Icon(Icons.edit, color: kPrimary), onPressed: () => _edit(i)),
                    IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => setState(() => _list.removeAt(i))),
                  ]),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ---------------- Admin (PIN 786) ----------------
class _AdminHomePage extends StatefulWidget {
  final List<Product> products;
  final List<AppCategory> categories;
  final void Function(List<AppCategory>) onCategoriesChanged;
  const _AdminHomePage({required this.products, required this.categories, required this.onCategoriesChanged});
  @override
  State<_AdminHomePage> createState() => _AdminHomePageState();
}

class _AdminHomePageState extends State<_AdminHomePage> {
  late List<Product> _products;
  late List<AppCategory> _categories;

  @override
  void initState() {
    super.initState();
    _products = widget.products;
    _categories = widget.categories;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('admin_panel')),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context, _products)),
          bottom: TabBar(
            isScrollable: true,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            tabs: [
              Tab(icon: Icon(Icons.dashboard), text: tr('dashboard')),
              Tab(icon: Icon(Icons.inventory), text: tr('products')),
              Tab(icon: Icon(Icons.category), text: tr('tab_categories')),
              Tab(icon: Icon(Icons.receipt_long), text: tr('orders')),
              Tab(icon: Icon(Icons.image), text: tr('banners')),
              Tab(icon: Icon(Icons.people), text: tr('customers')),
              Tab(icon: Icon(Icons.settings), text: tr('settings')),
            ],
          ),
        ),
        body: TabBarView(children: [
          const _DashboardPage(),
          _AdminProductsPage(products: _products, categories: _categories, onChanged: (l) => setState(() => _products = l)),
          _CategoriesPage(categories: _categories, onChanged: (l) {
            setState(() => _categories = l);
            widget.onCategoriesChanged(l);
          }),
          const _OrdersPage(),
          const _BannersPage(),
          const _CustomersPage(),
          const _SettingsPage(),
        ]),
      ),
    );
  }
}

class _AdminProductsPage extends StatefulWidget {
  final List<Product> products;
  final List<AppCategory> categories;
  final void Function(List<Product>) onChanged;
  const _AdminProductsPage({required this.products, required this.categories, required this.onChanged});
  @override
  State<_AdminProductsPage> createState() => _AdminProductsPageState();
}

class _AdminProductsPageState extends State<_AdminProductsPage> {
  late List<Product> _products;

  @override
  void initState() {
    super.initState();
    _products = widget.products;
  }

  Future<void> _refreshFromBackend() async {
    try {
      final remote = await fetchRemoteProducts();
      if (mounted && remote.isNotEmpty) setState(() => _products = remote);
    } catch (_) {}
  }

  void _editProduct(Product? existing, {int? index}) {
    final categories = widget.categories.map((c) => c.name).toList();
    if (existing != null && !categories.contains(existing.category)) categories.add(existing.category);
    if (categories.isEmpty) categories.add('Wash & Wear');
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urduCtrl = TextEditingController(text: existing?.urdu ?? '');
    final priceCtrl = TextEditingController(text: existing?.price?.toString() ?? '');
    final descCtrl = TextEditingController(text: existing?.desc ?? '');
    String category = existing?.category ?? categories[0];
    bool free = existing?.freeDelivery ?? false;
    String? imageUrl = existing?.image;
    String imageLabel = imageUrl == null ? tr('no_image') : tr('image_present');
    bool busy = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx2, setD) {
        Future<void> pick(ImageSource src) async {
          final file = await ImagePicker().pickImage(source: src, maxWidth: 1200, imageQuality: 80);
          if (file == null) return;
          setD(() => busy = true);
          try {
            imageUrl = await uploadProductImage(file);
            setD(() {
              busy = false;
              imageLabel = tr('image_uploaded');
            });
          } catch (_) {
            setD(() => busy = false);
            if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(tr('image_upload_failed'))));
          }
        }

        return AlertDialog(
          title: Text(existing == null ? tr('new_product') : tr('edit_product')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('name_req'))),
              TextField(controller: urduCtrl, decoration: InputDecoration(labelText: tr('urdu_name'))),
              TextField(controller: priceCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('price_req'))),
              DropdownButtonFormField<String>(
                value: category,
                decoration: InputDecoration(labelText: tr('category')),
                items: categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setD(() => category = v ?? categories[0]),
              ),
              TextField(controller: descCtrl, decoration: InputDecoration(labelText: tr('details'))),
              CheckboxListTile(value: free, onChanged: (v) => setD(() => free = v ?? false), title: Text(tr('free_delivery')), contentPadding: EdgeInsets.zero),
              const SizedBox(height: 8),
              Row(children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white),
                  onPressed: busy ? null : () async {
                    final src = await showDialog<ImageSource>(
                      context: ctx,
                      builder: (c2) => AlertDialog(
                        title: Text(tr('image_from')),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c2, ImageSource.camera), child: Text(tr('camera'))),
                          TextButton(onPressed: () => Navigator.pop(c2, ImageSource.gallery), child: Text(tr('gallery'))),
                        ],
                      ),
                    );
                    if (src != null) pick(src);
                  },
                  icon: const Icon(Icons.image),
                  label: Text(tr('choose_image')),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(imageLabel, style: const TextStyle(fontSize: 12))),
              ]),
              if (busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('back'))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white),
              onPressed: busy ? null : () async {
                if (nameCtrl.text.trim().isEmpty) return;
                if (priceCtrl.text.trim().isEmpty || int.tryParse(priceCtrl.text.trim()) == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(tr('enter_price'))));
                  return;
                }
                final draft = Product(
                  id: existing?.id ?? 'admin-${DateTime.now().millisecondsSinceEpoch}',
                  name: nameCtrl.text.trim(),
                  urdu: urduCtrl.text.trim(),
                  price: int.parse(priceCtrl.text.trim()),
                  image: imageUrl,
                  desc: descCtrl.text.trim(),
                  category: category,
                  freeDelivery: free,
                  sortOrder: existing?.sortOrder ?? 0,
                );
                try {
                  final saved = await upsertProduct(draft);
                  if (!ctx.mounted) return;
                  setState(() {
                    if (index != null) {
                      _products[index] = saved;
                    } else {
                      _products.add(saved);
                    }
                  });
                  widget.onChanged(_products);
                  Navigator.pop(ctx);
                } catch (_) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(tr('save_failed'))));
                }
              },
              child: Text(tr('save')),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _deleteProduct(int index) async {
    final p = _products[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('delete_q')),
        content: Text(trf('delete_product_confirm', {'name': p.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('no'))),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await deleteRemoteProduct(p.id);
      setState(() => _products.removeAt(index));
      widget.onChanged(_products);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('delete_failed'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        onPressed: () => _editProduct(null),
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshFromBackend,
        child: ListView.separated(
          padding: const EdgeInsets.all(14),
          itemCount: _products.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final p = _products[i];
            return Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(width: 52, height: 52, child: productImageWidget(p)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(rs(p.price ?? 0), style: const TextStyle(color: kPrimaryDark)),
                  Text(p.category + (p.freeDelivery ? tr('free_delivery_suffix') : ''), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ])),
                IconButton(icon: const Icon(Icons.edit, color: kPrimary), onPressed: () => _editProduct(p, index: i)),
                IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _deleteProduct(i)),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _OrdersPage extends StatefulWidget {
  const _OrdersPage();
  @override
  State<_OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<_OrdersPage> {
  List<FabricOrder> _orders = [];
  bool _loading = true;
  String? _error;
  int _section = 0;
  static const List<String> _statuses = ['Naya', 'Confirm', 'Tayyar', 'Delivered', 'Cancel'];

  /// 4 hisse: Naye | Raste Mein (Confirm+Tayyar) | Delivered | Cancelled.
  static const List<List<String>> _sections = [
    ['Naya'],
    ['Confirm', 'Tayyar'],
    ['Delivered'],
    ['Cancel'],
  ];
  static const List<String> _sectionKeys = ['orders_section_new', 'orders_section_transit', 'orders_section_delivered', 'orders_section_cancelled'];

  List<FabricOrder> get _visible => _orders.where((o) => _sections[_section].contains(o.status)).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await fetchRemoteOrders();
      if (mounted) setState(() => _orders = list);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setStatus(FabricOrder o, String s) async {
    try {
      await updateOrderStatus(o.id, s);
      if (mounted) setState(() => _orders[_orders.indexWhere((e) => e.id == o.id)] = FabricOrder(
        id: o.id, name: o.name, phone: o.phone, address: o.address, city: o.city,
        items: o.items, subtotal: o.subtotal, delivery: o.delivery, total: o.total,
        status: s, deliverySpeed: o.deliverySpeed, deliveryArea: o.deliveryArea, createdAt: o.createdAt,
      ));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('status_update_failed'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('orders_load_failed')),
        const SizedBox(height: 12),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white), onPressed: _load, child: Text(tr('try_again'))),
      ]));
    }
    if (_orders.isEmpty) return Center(child: Text(tr('no_orders_arrived')));
    final visible = _visible;
    return Column(children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
        child: Row(children: List.generate(_sections.length, (i) {
          final count = _orders.where((o) => _sections[i].contains(o.status)).length;
          final selected = _section == i;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text('${tr(_sectionKeys[i])} ($count)'),
              selected: selected,
              selectedColor: kPrimary,
              labelStyle: TextStyle(color: selected ? Colors.white : Colors.black87, fontWeight: FontWeight.bold),
              onSelected: (_) => setState(() => _section = i),
            ),
          );
        })),
      ),
      Expanded(
        child: visible.isEmpty
            ? Center(child: Text(tr('no_orders_section')))
            : RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(14),
        itemCount: visible.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final o = visible[i];
          return Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: ExpansionTile(
              title: Text(o.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${rs(o.total)} • ${o.dateText}'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ...o.items.map((it) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                            Expanded(child: Text('${it['name']} x${it['qty']}')),
                            Text(rs((it['price'] as num).toInt() * (it['qty'] as num).toInt())),
                          ]),
                        )),
                    const Divider(),
                    Text(trf('summary_line', {'subtotal': rs(o.subtotal), 'delivery': o.delivery == 0 ? tr('free') : rs(o.delivery), 'total': rs(o.total)})),
                    if (o.deliverySpeed.isNotEmpty) Text(trf('delivery_line', {'speed': speedLabelFor(o.deliverySpeed), 'area': areaLabelFor(o.deliveryArea)})),
                    Text(trf('phone_line', {'phone': o.phone})),
                    Text(trf('address_line', {'address': o.address, 'city': o.city})),
                    const SizedBox(height: 8),
                    Row(children: [
                      Text(tr('status_prefix')),
                      DropdownButton<String>(
                        value: _statuses.contains(o.status) ? o.status : 'Naya',
                        items: _statuses.map((s) => DropdownMenuItem(value: s, child: Text(statusLabel(s)))).toList(),
                        onChanged: (v) {
                          if (v != null) _setStatus(o, v);
                        },
                      ),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.call),
                        label: Text(tr('call_us')),
                        onPressed: () => openTel(o.phone),
                      ),
                    ]),
                  ]),
                ),
              ],
            ),
          );
        },
      ),
            ),
      ),
    ]);
  }
}

// ---------------- Admin: Dashboard ----------------
class _DashboardPage extends StatefulWidget {
  const _DashboardPage();
  @override
  State<_DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<_DashboardPage> {
  List<FabricOrder> _orders = [];
  List<Product> _products = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await fetchRemoteOrders();
      final products = await fetchRemoteProducts();
      if (mounted) {
        setState(() {
          _orders = orders;
          _products = products;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('dashboard_load_failed')),
        const SizedBox(height: 12),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white), onPressed: _load, child: Text(tr('try_again'))),
      ]));
    }
    final now = DateTime.now();
    final today = _orders.where((o) => o.createdAt.year == now.year && o.createdAt.month == now.month && o.createdAt.day == now.day).toList();
    final sale = _orders.where((o) => o.status != 'Cancel').fold<int>(0, (s, o) => s + o.total);
    final customers = _orders.map((o) => o.phone).toSet().length;
    final naye = _orders.where((o) => o.status == 'Naya').length;
    final recent = _orders.take(5).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(14), physics: const AlwaysScrollableScrollPhysics(), children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.4,
          children: [
            _statCard(tr('total_orders'), '${_orders.length}', Icons.receipt_long),
            _statCard(tr('notif_channel'), '$naye', Icons.fiber_new),
            _statCard(tr('total_sales'), rs(sale), Icons.attach_money),
            _statCard(tr('todays_orders'), '${today.length}', Icons.today),
            _statCard(tr('products'), '${_products.length}', Icons.inventory),
            _statCard(tr('customers'), '$customers', Icons.people),
          ],
        ),
        const SizedBox(height: 16),
        Text(tr('recent_orders'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (recent.isEmpty) Text(tr('no_orders_arrived')),
        ...recent.map((o) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                title: Text(o.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(o.dateText),
                trailing: Text(rs(o.total), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            )),
      ]),
    );
  }

  Widget _statCard(String label, String value, IconData icon) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: kPrimary),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(color: Colors.grey)),
        ]),
      );
}

// ---------------- Admin: Banners ----------------
class _BannersPage extends StatefulWidget {
  const _BannersPage();
  @override
  State<_BannersPage> createState() => _BannersPageState();
}

class _BannersPageState extends State<_BannersPage> {
  List<AdminBanner> _banners = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await fetchAllBanners();
      if (mounted) setState(() => _banners = list);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openForm([AdminBanner? existing]) async {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final subCtrl = TextEditingController(text: existing?.subtitle ?? '');
    final emojiCtrl = TextEditingController(text: existing?.emoji ?? '');
    final catCtrl = TextEditingController(text: existing?.category ?? 'Sab');
    final fromCtrl = TextEditingController(text: existing?.gradientFrom ?? '#14532D');
    final toCtrl = TextEditingController(text: existing?.gradientTo ?? '#0B3B20');
    final sortCtrl = TextEditingController(text: '${existing?.sortOrder ?? 0}');
    var active = existing?.active ?? true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(existing == null ? tr('new_banner') : tr('edit_banner')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: titleCtrl, decoration: InputDecoration(labelText: tr('title_req'))),
              TextField(controller: subCtrl, decoration: InputDecoration(labelText: tr('subtitle_label'))),
              TextField(controller: emojiCtrl, decoration: InputDecoration(labelText: tr('emoji_label'))),
              TextField(controller: catCtrl, decoration: InputDecoration(labelText: tr('category'))),
              TextField(controller: fromCtrl, decoration: InputDecoration(labelText: tr('colour_1'))),
              TextField(controller: toCtrl, decoration: InputDecoration(labelText: tr('colour_2'))),
              TextField(controller: sortCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('sort_number'))),
              SwitchListTile(title: Text(tr('active_label')), value: active, onChanged: (v) => setD(() => active = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('back'))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white),
              onPressed: () async {
                if (titleCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('enter_title'))));
                  return;
                }
                try {
                  await upsertBanner(AdminBanner(
                    id: existing?.id ?? 'new-${DateTime.now().millisecondsSinceEpoch}',
                    title: titleCtrl.text.trim(),
                    subtitle: subCtrl.text.trim(),
                    emoji: emojiCtrl.text.trim(),
                    category: catCtrl.text.trim().isEmpty ? 'Sab' : catCtrl.text.trim(),
                    gradientFrom: fromCtrl.text.trim().isEmpty ? '#14532D' : fromCtrl.text.trim(),
                    gradientTo: toCtrl.text.trim().isEmpty ? '#0B3B20' : toCtrl.text.trim(),
                    sortOrder: int.tryParse(sortCtrl.text.trim()) ?? 0,
                    active: active,
                  ));
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (_) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(tr('banner_save_failed'))));
                }
              },
              child: Text(tr('save')),
            ),
          ],
        ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(AdminBanner b) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('delete_banner_q')),
        content: Text(trf('delete_banner_confirm', {'name': b.title})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('no'))),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await deleteRemoteBanner(b.id);
      _load();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('delete_failed'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('banners_load_failed')),
        const SizedBox(height: 12),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white), onPressed: _load, child: Text(tr('try_again'))),
      ]));
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton(backgroundColor: kPrimary, foregroundColor: Colors.white, onPressed: () => _openForm(), child: const Icon(Icons.add)),
      body: _banners.isEmpty
          ? Center(child: Text(tr('no_banners')))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(14),
                itemCount: _banners.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final b = _banners[i];
                  return Container(
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      leading: Text(b.emoji, style: const TextStyle(fontSize: 26)),
                      title: Text(b.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${b.subtitle} • ${b.category} • ${b.active ? tr('active_label') : tr('inactive_label')}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(icon: const Icon(Icons.edit), onPressed: () => _openForm(b)),
                        IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _delete(b)),
                      ]),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

// ---------------- Admin: Customers ----------------
class _CustomersPage extends StatefulWidget {
  const _CustomersPage();
  @override
  State<_CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<_CustomersPage> {
  List<FabricOrder> _orders = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await fetchRemoteOrders();
      if (mounted) setState(() => _orders = list);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('customers_load_failed')),
        const SizedBox(height: 12),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white), onPressed: _load, child: Text(tr('try_again'))),
      ]));
    }
    final byPhone = <String, List<FabricOrder>>{};
    for (final o in _orders) {
      byPhone.putIfAbsent(o.phone, () => []).add(o);
    }
    final entries = byPhone.entries.toList()..sort((a, b) => b.value.first.createdAt.compareTo(a.value.first.createdAt));
    if (entries.isEmpty) return Center(child: Text(tr('no_customers')));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(14),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final phone = entries[i].key;
          final list = entries[i].value;
          final spent = list.where((o) => o.status != 'Cancel').fold<int>(0, (s, o) => s + o.total);
          return Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: CircleAvatar(backgroundColor: kPrimary, foregroundColor: Colors.white, child: Text(list.first.name.isNotEmpty ? list.first.name[0].toUpperCase() : '?')),
              title: Text(list.first.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(trf('customer_row', {'phone': phone, 'count': list.length, 'total': rs(spent)})),
              trailing: IconButton(
                icon: const Icon(Icons.call, color: kPrimary),
                onPressed: () => openTel(phone),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------- Admin: Settings ----------------
class _SettingsPage extends StatefulWidget {
  const _SettingsPage();
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  final Map<String, TextEditingController> _feeCtrls = {for (final k in kDefaultFees.keys) k: TextEditingController()};
  final _annCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _feeCtrls.values) c.dispose();
    _annCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await fetchRemoteSettings();
      if (mounted) {
        setState(() {
          for (final k in kDefaultFees.keys) {
            _feeCtrls[k]!.text = '${migrateFeeValue(k, int.tryParse('${s[k] ?? ''}') ?? kDefaultFees[k]!)}';
          }
          _annCtrl.text = '${s['announcement'] ?? ''}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      for (final k in kDefaultFees.keys) {
        await updateRemoteSetting(k, _feeCtrls[k]!.text.trim());
      }
      await updateRemoteSetting('announcement', _annCtrl.text.trim());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('settings_saved'))));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('settings_save_failed'))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _feeLabel(String key) {
    if (key == 'fee_outside') return areaLabel(3);
    final parts = key.replaceFirst('fee_', '').split('_');
    final areaIdx = {'near': 0, 'mid': 1, 'far': 2}[parts[0]] ?? 0;
    final speedIdx = {'normal': 0, 'medium': 1, 'urgent': 2}[parts[1]] ?? 0;
    return '${areaLabel(areaIdx)} — ${speedLabel(speedIdx)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('settings_load_failed')),
        const SizedBox(height: 12),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white), onPressed: _load, child: Text(tr('try_again'))),
      ]));
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(tr('delivery_fees_title'), style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      ...kDefaultFees.keys.map((k) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(controller: _feeCtrls[k], keyboardType: TextInputType.number, decoration: InputDecoration(border: const OutlineInputBorder(), labelText: _feeLabel(k))),
          )),
      const SizedBox(height: 8),
      Text(tr('announcement_label'), style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      TextField(controller: _annCtrl, maxLines: 3, decoration: InputDecoration(border: OutlineInputBorder(), hintText: tr('announcement_hint'))),
      const SizedBox(height: 20),
      ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
        onPressed: _saving ? null : _save,
        child: Text(_saving ? tr('saving') : tr('save')),
      ),
    ]);
  }
}

// ---------------- Admin: Categories ----------------
class _CategoriesPage extends StatefulWidget {
  final List<AppCategory> categories;
  final void Function(List<AppCategory>) onChanged;
  const _CategoriesPage({required this.categories, required this.onChanged});
  @override
  State<_CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<_CategoriesPage> {
  late List<AppCategory> _cats;
  final TextEditingController _nameCtrl = TextEditingController();
  String _icon = 'category';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _cats = List.of(widget.categories);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _persist(List<AppCategory> next) async {
    setState(() => _busy = true);
    try {
      await saveRemoteCategories(next);
      setState(() => _cats = next);
      widget.onChanged(next);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('cat_save_failed'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _add() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('cat_no_name'))));
      return;
    }
    if (_cats.any((c) => c.name.toLowerCase() == name.toLowerCase())) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('cat_dup'))));
      return;
    }
    _nameCtrl.clear();
    _persist([..._cats, AppCategory(name, _icon)]);
  }

  Future<void> _delete(AppCategory cat) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('cat_delete_title')),
        content: Text(tr('cat_delete_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (ok == true) {
      _persist(_cats.where((c) => c.name != cat.name).toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: _nameCtrl, decoration: InputDecoration(labelText: tr('cat_name'), border: const OutlineInputBorder())),
      const SizedBox(height: 12),
      Text(tr('cat_icon'), style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: kCategoryIcons.entries.map((e) {
          final selected = _icon == e.key;
          return InkWell(
            onTap: () => setState(() => _icon = e.key),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: selected ? kPrimary : Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: selected ? kPrimary : Colors.grey.shade300)),
              child: Icon(e.value, color: selected ? Colors.white : kPrimary),
            ),
          );
        }).toList(),
      ),
      const SizedBox(height: 12),
      ElevatedButton.icon(onPressed: _busy ? null : _add, icon: const Icon(Icons.add), label: Text(tr('cat_add')), style: ElevatedButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white)),
      const SizedBox(height: 16),
      if (_cats.isEmpty) Center(child: Text(tr('cat_empty'))),
      ..._cats.map((c) => Card(
            child: ListTile(
              leading: Icon(kCategoryIcons[c.icon] ?? Icons.category, color: kPrimary),
              title: Text(c.name),
              trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: _busy ? null : () => _delete(c)),
            ),
          )),
    ]);
  }
}
