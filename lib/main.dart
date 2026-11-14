import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

const red = Color(0xFFC62032);
const gold = Color(0xFFE0B75C);
const bg = Color(0xFF101014);
const storeAddress = 'سوق الجمعة، الحشان، باتجاه شارع الغاز';
const phones = ['0915206879', '0923319182', '0925206879'];
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
late SupabaseClient db;
bool get configured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (configured) {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseKey);
    db = Supabase.instance.client;
  }
  runApp(const JokerApp());
}

class JokerApp extends StatelessWidget {
  const JokerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'متجر الجوكر',
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: red, brightness: Brightness.dark, secondary: gold),
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: gold)),
    builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox()),
    home: const StorePage(),
  );
}

void notice(BuildContext context, String text) {
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

Future<void> openExternal(String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'tel')) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class StorePage extends StatefulWidget {
  const StorePage({super.key});
  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> socials = [];
  List<String> categories = [];
  final Map<String, int> cart = {};
  String category = 'الكل';
  String query = '';
  bool loading = false;
  bool liked = false;
  int likes = 0;
  String? visitorToken;

  @override
  void initState() { super.initState(); load(); }

  Future<void> load() async {
    if (!configured) return;
    setState(() => loading = true);
    try {
      final p = await db.from('products').select().order('created_at', ascending: false);
      final c = await db.from('categories').select('name').order('name');
      final s = await db.from('social_links').select().eq('enabled', true);
      final prefs = await SharedPreferences.getInstance();
      var token = prefs.getString('joker_visitor_token');
      if (token == null) {
        token = const Uuid().v4();
        await prefs.setString('joker_visitor_token', token);
      }
      final count = await db.rpc('like_count');
      final mine = await db.rpc('my_store_like', params: {'p_token': token});
      if (mounted) setState(() {
        products = List<Map<String, dynamic>>.from(p);
        categories = List<Map<String, dynamic>>.from(c).map((e) => '${e['name']}').toList();
        socials = List<Map<String, dynamic>>.from(s);
        likes = (count as num).toInt(); liked = mine == true; visitorToken = token;
      });
    } catch (e) { if (mounted) notice(context, 'تعذر تحميل بيانات المتجر: $e'); }
    if (mounted) setState(() => loading = false);
  }

  Future<void> toggleLike() async {
    if (!configured || visitorToken == null) return;
    try {
      final next = !liked;
      final result = await db.rpc('toggle_store_like', params: {'p_token': visitorToken, 'p_liked': next});
      if (mounted) setState(() { liked = next; likes = (result as num).toInt(); });
    } catch (_) { if (mounted) notice(context, 'تعذر حفظ الإعجاب'); }
  }

  double get total => products.fold<double>(0, (sum, p) => sum + ((p['price'] as num).toDouble() * (cart['${p['id']}'] ?? 0)));
  Future<void> checkout() async {
    if (cart.values.every((n) => n == 0)) { notice(context, 'السلة فارغة'); return; }
    final name = TextEditingController(), phone = TextEditingController(), address = TextEditingController();
    await showDialog<void>(context: context, builder: (dialog) => AlertDialog(
      title: const Text('إتمام الطلب'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم الزبون')),
        TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')),
        TextField(controller: address, decoration: const InputDecoration(labelText: 'عنوان التوصيل')),
        const SizedBox(height: 12), Text('الإجمالي: ${total.toStringAsFixed(2)} د.ل'),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('إلغاء')),
        FilledButton(onPressed: () async {
          if (name.text.trim().isEmpty || phone.text.trim().length < 7 || address.text.trim().isEmpty) {
            notice(context, 'أدخل الاسم والهاتف والعنوان'); return;
          }
          try {
            final items = cart.entries.where((e) => e.value > 0).map((e) => {'product_id': e.key, 'quantity': e.value}).toList();
            await db.rpc('place_order', params: {'p_customer': name.text.trim(), 'p_phone': phone.text.trim(), 'p_address': address.text.trim(), 'p_items': items});
            if (dialog.mounted) Navigator.pop(dialog);
            if (mounted) { setState(cart.clear); notice(context, 'تم تسجيل الطلب بنجاح'); await load(); }
          } catch (e) { if (mounted) notice(context, 'لم يتم تسجيل الطلب: $e'); }
        }, child: const Text('تأكيد الطلب'))],
    ));
    name.dispose(); phone.dispose(); address.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = products.where((p) => (category == 'الكل' || p['category'] == category) && '${p['name']}'.toLowerCase().contains(query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('🃏 متجر الجوكر'), actions: [
        IconButton(tooltip: 'تحديث', onPressed: load, icon: const Icon(Icons.refresh)),
        IconButton(tooltip: 'لوحة الإدارة', onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPage())); load(); }, icon: const Icon(Icons.admin_panel_settings)),
      ]),
      body: RefreshIndicator(onRefresh: load, child: ListView(padding: const EdgeInsets.all(14), children: [
        Center(child: Image.asset('assets/images/logo.png', height: 155)),
        const Center(child: Text('الإلكترونيات والكماليات', style: TextStyle(color: gold, fontSize: 21, fontWeight: FontWeight.bold))),
        const SizedBox(height: 8), const Center(child: Text(storeAddress, textAlign: TextAlign.center)),
        Wrap(alignment: WrapAlignment.center, spacing: 8, children: phones.map((p) => TextButton(onPressed: () => openExternal('tel:$p'), child: Text(p))).toList()),
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
          const Text('محبة زبائن متجر الجوكر', style: TextStyle(color: gold, fontSize: 18)),
          Text('$likes ❤️', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          FilledButton.icon(onPressed: configured ? toggleLike : null, icon: Icon(liked ? Icons.favorite : Icons.favorite_border), label: Text(liked ? 'إلغاء الإعجاب' : 'أعجبني المتجر')),
          TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FeedbackPage())), icon: const Icon(Icons.star), label: const Text('قيّم المتجر وأرسل اقتراحك')),
        ]))),
        const SizedBox(height: 10),
        TextField(onChanged: (v) => setState(() => query = v), decoration: const InputDecoration(labelText: 'ابحث عن منتج', prefixIcon: Icon(Icons.search), border: OutlineInputBorder())),
        const SizedBox(height: 10),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: ['الكل', ...categories].map((c) => Padding(padding: const EdgeInsets.only(left: 6), child: ChoiceChip(label: Text(c), selected: category == c, onSelected: (_) => setState(() => category = c)))).toList())),
        if (loading) const Center(child: CircularProgressIndicator()),
        if (!configured) const Padding(padding: EdgeInsets.all(20), child: Text('يلزم إعداد Supabase لعرض المنتجات وحفظ الطلبات.')),
        if (!loading && configured && filtered.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('لا توجد منتجات حاليًا')),
        ...filtered.map((p) {
          final id = '${p['id']}'; final stock = (p['stock'] as num).toInt(); final qty = cart[id] ?? 0;
          return Card(child: Padding(padding: const EdgeInsets.all(10), child: Row(children: [
            SizedBox(width: 90, height: 90, child: '${p['image_url']}'.isNotEmpty ? Image.network('${p['image_url']}', fit: BoxFit.cover, errorBuilder: (context, error, stackTrace) =>
    const Icon(Icons.devices, size: 50)) : const Icon(Icons.devices, size: 50)),
            const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p['name']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              Text('${p['description']}', maxLines: 2, overflow: TextOverflow.ellipsis),
              Text('${p['price']} د.ل', style: const TextStyle(color: gold)),
              Text('المتوفر: $stock'),
              Row(children: [IconButton(onPressed: qty > 0 ? () => setState(() { if (qty == 1) { cart.remove(id); } else { cart[id] = qty - 1; } }) : null, icon: const Icon(Icons.remove_circle_outline)), Text('$qty'), IconButton(onPressed: qty < stock ? () => setState(() => cart[id] = qty + 1) : null, icon: const Icon(Icons.add_circle_outline, color: gold))]),
            ]))
          ])));
        }),
        const SizedBox(height: 12), Text('إجمالي السلة: ${total.toStringAsFixed(2)} د.ل', style: const TextStyle(color: gold, fontSize: 20)),
        FilledButton.icon(onPressed: configured ? checkout : null, icon: const Icon(Icons.shopping_cart_checkout), label: const Text('إتمام الطلب')),
        const SizedBox(height: 18), const Text('تابع متجر الجوكر', style: TextStyle(fontSize: 20, color: gold)),
        Wrap(spacing: 8, children: socials.map((s) => ActionChip(label: Text('${s['label']}'), onPressed: () => openExternal('${s['url']}'))).toList()),
        const SizedBox(height: 18), FilledButton.tonalIcon(onPressed: () => openExternal('https://wa.me/218915206879'), icon: const Icon(Icons.chat), label: const Text('تواصل معنا عبر واتساب')),
      ])),
    );
  }
}

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});
  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}
class _FeedbackPageState extends State<FeedbackPage> {
  int rating = 5;
  final note = TextEditingController();
  bool busy = false;
  @override
  void dispose() { note.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('رأيك يهمنا')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      const Text('ما مدى رضاك عن متجر الجوكر وخدماته؟', style: TextStyle(fontSize: 20)),
      Wrap(children: List.generate(5, (i) => IconButton(onPressed: () => setState(() => rating = i + 1), icon: Icon(i < rating ? Icons.star : Icons.star_border, color: gold, size: 33)))),
      TextField(controller: note, maxLines: 5, maxLength: 2000, decoration: const InputDecoration(labelText: 'اقتراح أو ملاحظة (اختياري)', border: OutlineInputBorder())),
      FilledButton(onPressed: busy || !configured ? null : () async {
        setState(() => busy = true);
        try { await db.rpc('submit_feedback', params: {'p_rating': rating, 'p_message': note.text.trim()});
          if (context.mounted) { notice(context, 'شكرًا على تقييمك'); Navigator.pop(context); }
        } catch (e) { if (context.mounted) notice(context, 'تعذر إرسال التقييم: $e'); }
        if (mounted) setState(() => busy = false);
      }, child: const Text('إرسال التقييم والاقتراح')),
    ]));
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});
  @override
  State<AdminPage> createState() => _AdminPageState();
}
class _AdminPageState extends State<AdminPage> {
  final username = TextEditingController(), password = TextEditingController();
  bool busy = false;
  bool owner = false;
  Map<String, dynamic> permissions = {};
  List<Map<String, dynamic>> products = [], orders = [], feedback = [], staff = [], social = [];
  bool get signedIn => configured && db.auth.currentUser != null;
  bool can(String key) => owner || permissions['can_$key'] == true;
  @override
  void initState() { super.initState(); if (signedIn) refresh(); }
  @override
  void dispose() { username.dispose(); password.dispose(); super.dispose(); }

  Future<void> login() async {
    if (!configured) { notice(context, 'يرجى إعداد Supabase أولًا'); return; }
    setState(() => busy = true);
    try {
      final user = username.text.trim();
      if (user.contains('@')) {
        await db.auth.signInWithPassword(email: user, password: password.text);
      } else {
        final response = await db.functions.invoke('staff-login', body: {'username': user, 'password': password.text});
        if (response.status != 200 || response.data is! Map) throw Exception('بيانات الدخول غير صحيحة');
        final data = Map<String, dynamic>.from(response.data as Map);
        final access = data['access_token']; final refresh = data['refresh_token'];
        if (access is! String || refresh is! String) throw Exception('لم تُرجع الخدمة جلسة صالحة');
        await db.auth.setSession(refresh);
      }
      await refresh();
    } catch (e) { if (mounted) notice(context, 'تعذر تسجيل الدخول: $e'); }
    if (mounted) setState(() => busy = false);
  }

  Future<void> refresh() async {
    if (!signedIn) return;
    try {
      final own = await db.rpc('is_store_owner');
      final uid = db.auth.currentUser!.id;
      final perms = await db.from('staff_permissions').select().eq('user_id', uid).maybeSingle();
      if (mounted) setState(() { owner = own == true; permissions = perms ?? {}; });
      if (owner || can('edit_products') || can('add_products') || can('change_prices') || can('manage_stock') || can('manage_images') || can('delete_products')) {
        final p = await db.from('products').select().order('created_at', ascending: false);
        if (mounted) setState(() => products = List<Map<String, dynamic>>.from(p));
      }
      if (owner || can('view_orders') || can('manage_orders')) {
        final o = await db.from('orders').select().order('created_at', ascending: false).limit(100);
        if (mounted) setState(() => orders = List<Map<String, dynamic>>.from(o));
      }
      if (owner) {
        final f = await db.from('customer_feedback').select().order('created_at', ascending: false).limit(100);
        final s = await db.from('staff_profiles').select().order('username');
        final links = await db.from('social_links').select().order('platform');
        if (mounted) setState(() { feedback = List<Map<String, dynamic>>.from(f); staff = List<Map<String, dynamic>>.from(s); social = List<Map<String, dynamic>>.from(links); });
      }
    } catch (e) { if (mounted) notice(context, 'تعذر تحميل الإدارة: $e'); }
  }

  Future<void> editProduct([Map<String, dynamic>? product]) async {
    final name = TextEditingController(text: '${product?['name'] ?? ''}');
    final category = TextEditingController(text: '${product?['category'] ?? 'هواتف'}');
    final description = TextEditingController(text: '${product?['description'] ?? ''}');
    final price = TextEditingController(text: '${product?['price'] ?? ''}');
    final stock = TextEditingController(text: '${product?['stock'] ?? 0}');
    String imageUrl = '${product?['image_url'] ?? ''}';
    Uint8List? bytes; String? imageName;
    await showDialog<void>(context: context, builder: (dialog) => StatefulBuilder(builder: (ctx, change) => AlertDialog(
      title: Text(product == null ? 'إضافة منتج' : 'تعديل منتج'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم المنتج')),
        TextField(controller: category, decoration: const InputDecoration(labelText: 'القسم (يجب أن يكون موجودًا)')),
        TextField(controller: description, decoration: const InputDecoration(labelText: 'الوصف')),
        TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'السعر')),
        TextField(controller: stock, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الكمية')),
        TextButton.icon(onPressed: can('manage_images') ? () async {
          final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
          if (x != null) { bytes = await x.readAsBytes(); imageName = x.name; change(() {}); }
        } : null, icon: const Icon(Icons.photo), label: Text(imageName == null ? 'اختيار صورة' : 'تم اختيار $imageName')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('إلغاء')),
        FilledButton(onPressed: () async {
          final amount = double.tryParse(price.text), quantity = int.tryParse(stock.text);
          if (name.text.trim().isEmpty || amount == null || amount < 0 || quantity == null || quantity < 0) { notice(context, 'تحقق من الاسم والسعر والمخزون'); return; }
          try {
            if (bytes != null) {
              final safe = (imageName ?? 'photo.jpg').replaceAll(RegExp(r'[^a-zA-Z0-9.]'), '_');
              final path = '${const Uuid().v4()}_$safe';
              await db.storage.from('product-images').uploadBinary(path, bytes!);
              imageUrl = db.storage.from('product-images').getPublicUrl(path);
            }
            final data = <String, dynamic>{'name': name.text.trim(), 'category': category.text.trim(), 'description': description.text.trim(), 'price': amount, 'stock': quantity, 'image_url': imageUrl};
            if (product == null) {
              data['id'] = const Uuid().v4();
              await db.from('products').insert(data);
            } else {
              await db.from('products').update(data).eq('id', product['id']);
            }
            if (dialog.mounted) Navigator.pop(dialog);
            await refresh();
          } catch (e) { if (mounted) notice(context, 'تعذر حفظ المنتج: $e'); }
        }, child: const Text('حفظ'))],
    )));
    name.dispose(); category.dispose(); description.dispose(); price.dispose(); stock.dispose();
  }

  Future<void> editSocial(Map<String, dynamic> link) async {
    final controller = TextEditingController(text: '${link['url']}');
    var enabled = link['enabled'] == true;
    await showDialog<void>(context: context, builder: (dialog) => StatefulBuilder(builder: (ctx, change) => AlertDialog(
      title: Text('${link['label']}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: controller, decoration: const InputDecoration(labelText: 'رابط HTTPS')),
        SwitchListTile(value: enabled, onChanged: (v) => change(() => enabled = v), title: const Text('إظهار الرابط')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('إلغاء')),
        FilledButton(onPressed: () async {
          if (enabled && !controller.text.startsWith('https://')) { notice(context, 'أدخل رابط HTTPS صحيحًا'); return; }
          try { await db.from('social_links').update({'url': controller.text.trim(), 'enabled': enabled}).eq('platform', link['platform']);
            if (dialog.mounted) Navigator.pop(dialog); await refresh();
          } catch (e) { if (mounted) notice(context, '$e'); }
        }, child: const Text('حفظ'))],
    )));
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('إدارة متجر الجوكر'), actions: [
    if (signedIn) IconButton(onPressed: () async { await db.auth.signOut(); if (mounted) setState(() { owner = false; permissions = {}; }); }, icon: const Icon(Icons.logout)),
  ]), body: !signedIn ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
    const Text('دخول المدير أو الموظف', style: TextStyle(fontSize: 22, color: gold)),
    TextField(controller: username, decoration: const InputDecoration(labelText: 'اسم المستخدم للموظف أو بريد المدير')),
    TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')),
    const SizedBox(height: 16), FilledButton(onPressed: busy ? null : login, child: const Text('دخول')),
  ]))) : RefreshIndicator(onRefresh: refresh, child: ListView(padding: const EdgeInsets.all(14), children: [
    Text(owner ? 'المدير الرئيسي' : 'حساب موظف', style: const TextStyle(color: gold, fontSize: 21)),
    if (owner || can('add_products')) FilledButton.icon(onPressed: () => editProduct(), icon: const Icon(Icons.add), label: const Text('إضافة منتج')),
    if (owner || can('edit_products') || can('change_prices') || can('manage_stock') || can('manage_images') || can('delete_products')) ...[
      const Divider(), const Text('المنتجات', style: TextStyle(fontSize: 19)),
      ...products.map((p) => Card(child: ListTile(title: Text('${p['name']}'), subtitle: Text('${p['price']} د.ل | مخزون: ${p['stock']}'),
        trailing: Wrap(children: [
          if (owner || can('edit_products') || can('change_prices') || can('manage_stock') || can('manage_images')) IconButton(onPressed: () => editProduct(p), icon: const Icon(Icons.edit)),
          if (owner || can('delete_products')) IconButton(onPressed: () async { try { await db.from('products').delete().eq('id', p['id']); await refresh(); } catch (e) { if (context.mounted) notice(context, '$e'); } }, icon: const Icon(Icons.delete_outline)),
        ])))),
    ],
    if (owner || can('view_orders') || can('manage_orders')) ...[
      const Divider(), const Text('الطلبات', style: TextStyle(fontSize: 19)),
      ...orders.map((o) => Card(child: ListTile(title: Text('${o['customer']} — ${o['total']} د.ل'), subtitle: Text('${o['phone']} | ${o['address']}\n${o['status']}'), isThreeLine: true,
        trailing: (owner || can('manage_orders')) ? PopupMenuButton<String>(onSelected: (status) async { try { await db.from('orders').update({'status': status}).eq('id', o['id']); await refresh(); } catch (e) { if (context.mounted) notice(context, '$e'); } }, itemBuilder: (_) => ['جديد', 'قيد التجهيز', 'تم التسليم', 'ملغي'].map((s) => PopupMenuItem(value: s, child: Text(s))).toList()) : null))),
    ],
    if (owner) ...[
      const Divider(), const Text('التقييمات والاقتراحات', style: TextStyle(fontSize: 19)),
      ...feedback.map((f) => ListTile(leading: const Icon(Icons.star, color: gold), title: Text('${f['rating']} / 5'), subtitle: Text('${f['message']}'))),
      const Divider(), const Text('حسابات الموظفين (للعرض)', style: TextStyle(fontSize: 19)),
      ...staff.map((s) => ListTile(leading: const Icon(Icons.person), title: Text('${s['display_name']}'), subtitle: Text('${s['username']} — ${s['is_active'] == true ? 'نشط' : 'معطّل'}'))),
      const Text('إنشاء الموظفين وتعديل صلاحياتهم يتم حاليًا من Supabase، وليس من هذه الشاشة.', style: TextStyle(color: gold)),
      const Divider(), const Text('روابط منصات المتجر', style: TextStyle(fontSize: 19)),
      ...social.map((s) => ListTile(title: Text('${s['label']}'), subtitle: Text('${s['url']}'), trailing: IconButton(onPressed: () => editSocial(s), icon: const Icon(Icons.edit)))),
    ],
  ])));
}
