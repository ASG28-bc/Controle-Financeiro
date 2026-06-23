import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:local_auth/local_auth.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DB.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Controle Financeiro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E88E5)),
      ),
      home: const AuthGate(),
    );
  }
}

// ========== BIOMETRIA ==========
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final LocalAuthentication auth = LocalAuthentication();
  bool _autenticado = false;

  @override
  void initState() {
    super.initState();
    _autenticar();
  }

  Future<void> _autenticar() async {
    try {
      bool podeChecar = await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (!podeChecar) {
        setState(() => _autenticado = true);
        return;
      }
      bool fez = await auth.authenticate(
        localizedReason: 'Autentique para acessar o Controle Financeiro',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
      if (fez) setState(() => _autenticado = true);
    } on PlatformException {
      setState(() => _autenticado = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_autenticado) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock, size: 64, color: Colors.blue),
              const SizedBox(height: 16),
              const Text('Autenticação necessária', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _autenticar,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Tentar Novamente'),
              ),
              const SizedBox(height: 40),
              const Text('© SS-Tecnologia - (47) 98802-0676', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    return const HomePage();
  }
}

// ========== BANCO DE DADOS ==========
class DB {
  static Database? _db;
  static const uuid = Uuid();

  static Future<void> init() async {
    String path = join(await getDatabasesPath(), 'finance.db');
    _db = await openDatabase(path, version: 1, onCreate: _createDB);
    await _processarRecorrentes();
  }

  static Future _createDB(Database db, int version) async {
    await db.execute('CREATE TABLE contas(id TEXT PRIMARY KEY, nome TEXT, saldo REAL, tipo TEXT)');
    await db.execute('CREATE TABLE categorias(id TEXT PRIMARY KEY, nome TEXT, tipo TEXT)');
    await db.execute('CREATE TABLE lancamentos(id TEXT PRIMARY KEY, valor REAL, tipo TEXT, categoria_id TEXT, conta_id TEXT, data TEXT, descricao TEXT, recorrente_id TEXT, parcela_id TEXT)');
    await db.execute('CREATE TABLE recorrentes(id TEXT PRIMARY KEY, descricao TEXT, valor REAL, categoria_id TEXT, conta_id TEXT, dia INTEGER, tipo TEXT, data_inicio TEXT, ultima_execucao TEXT)');
    await db.execute('CREATE TABLE compras_parceladas(id TEXT PRIMARY KEY, descricao TEXT, valor_total REAL, qtd_parcelas INTEGER, data_compra TEXT, conta_id TEXT, categoria_id TEXT)');
    await db.execute('CREATE TABLE parcelas(id TEXT PRIMARY KEY, compra_id TEXT, numero INTEGER, valor REAL, vencimento TEXT, paga INTEGER)');
    await db.execute('CREATE TABLE uber_corridas(id TEXT PRIMARY KEY, data TEXT, valor_bruto REAL, taxa_app REAL, valor_liquido REAL, km REAL, horas REAL, conta_id TEXT)');
    await db.execute('CREATE TABLE abastecimentos(id TEXT PRIMARY KEY, data TEXT, litros REAL, valor REAL, km_atual REAL, posto TEXT, conta_id TEXT)');

    await db.insert('contas', {'id': uuid.v4(), 'nome': 'Carteira', 'saldo': 0, 'tipo': 'CARTEIRA'});
    await db.insert('contas', {'id': uuid.v4(), 'nome': 'Nubank', 'saldo': 0, 'tipo': 'CORRENTE'});

    var cats = [
      {'id': uuid.v4(), 'nome': 'Alimentação', 'tipo': 'SAIDA'},
      {'id': uuid.v4(), 'nome': 'Transporte', 'tipo': 'SAIDA'},
      {'id': uuid.v4(), 'nome': 'Casa', 'tipo': 'SAIDA'},
      {'id': uuid.v4(), 'nome': 'Lazer', 'tipo': 'SAIDA'},
      {'id': uuid.v4(), 'nome': 'Saúde', 'tipo': 'SAIDA'},
      {'id': uuid.v4(), 'nome': 'Salário', 'tipo': 'ENTRADA'},
      {'id': uuid.v4(), 'nome': 'Uber - Corrida', 'tipo': 'ENTRADA'},
      {'id': uuid.v4(), 'nome': 'Combustível', 'tipo': 'SAIDA'},
      {'id': uuid.v4(), 'nome': 'Transferência', 'tipo': 'AMBOS'},
    ];
    for (var c in cats) await db.insert('categorias', c);
  }

  static Future<List<Map>> getContas() async => await _db!.query('contas', orderBy: 'nome');
  static Future addConta(String nome, String tipo) async {
    await _db!.insert('contas', {'id': uuid.v4(), 'nome': nome, 'saldo': 0, 'tipo': tipo});
  }

  static Future<List<Map>> getCategorias() async => await _db!.query('categorias', orderBy: 'nome');

  static Future addLancamento(Map data) async {
    data['id'] = data['id']?? uuid.v4();
    await _db!.insert('lancamentos', data);
    double novoSaldo = data['tipo'] == 'ENTRADA'? data['valor'] : -data['valor'];
    await _db!.rawUpdate('UPDATE contas SET saldo = saldo +? WHERE id =?', [novoSaldo, data['conta_id']]);
  }

  static Future<List<Map>> getLancamentosMes() async {
    String mes = DateFormat('yyyy-MM').format(DateTime.now());
    return await _db!.rawQuery('SELECT l.*, c.nome as conta_nome, cat.nome as categoria_nome FROM lancamentos l LEFT JOIN contas c ON l.conta_id = c.id LEFT JOIN categorias cat ON l.categoria_id = cat.id WHERE l.data LIKE? ORDER BY l.id DESC', ['$mes%']);
  }

  static Future<List<FlSpot>> getEvolucaoSaldo() async {
    List<FlSpot> spots = [];
    DateTime hoje = DateTime.now();
    for (int i = 5; i >= 0; i--) {
      DateTime mes = DateTime(hoje.year, hoje.month - i, 1);
      String mesStr = DateFormat('yyyy-MM').format(mes);
      var result = await _db!.rawQuery('SELECT SUM(CASE WHEN tipo = \'ENTRADA\' THEN valor ELSE -valor END) as saldo FROM lancamentos WHERE data <=?', ['${mesStr}-31']);
      double saldo = (result[0]['saldo'] as num?)?.toDouble()?? 0;
      spots.add(FlSpot((5-i).toDouble(), saldo));
    }
    return spots;
  }

  static Future transferir(String origemId, String destinoId, double valor) async {
    String data = DateFormat('yyyy-MM-dd').format(DateTime.now());
    String catTransf = (await _db!.query('categorias', where: 'nome =?', whereArgs: ['Transferência']))[0]['id'];
    await addLancamento({'valor': valor, 'tipo': 'SAIDA', 'categoria_id': catTransf, 'conta_id': origemId, 'data': data, 'descricao': 'Transferência enviada'});
    await addLancamento({'valor': valor, 'tipo': 'ENTRADA', 'categoria_id': catTransf, 'conta_id': destinoId, 'data': data, 'descricao': 'Transferência recebida'});
  }

  static Future addRecorrente(Map data) async {
    data['id'] = uuid.v4();
    data['data_inicio'] = DateFormat('yyyy-MM-dd').format(DateTime.now());
    await _db!.insert('recorrentes', data);
  }

  static Future<List<Map>> getRecorrentes() async => await _db!.rawQuery('SELECT r.*, c.nome as conta_nome, cat.nome as categoria_nome FROM recorrentes r LEFT JOIN contas c ON r.conta_id = c.id LEFT JOIN categorias cat ON r.categoria_id = cat.id');

  static Future _processarRecorrentes() async {
    var recorrentes = await _db!.query('recorrentes');
    String hoje = DateFormat('yyyy-MM-dd').format(DateTime.now());
    String mesAtual = DateFormat('yyyy-MM').format(DateTime.now());
    for (var r in recorrentes) {
      int dia = r['dia'];
      String? ultimaExec = r['ultima_execucao'];
      String dataVencimento = '$mesAtual-${dia.toString().padLeft(2, '0')}';
      if (DateTime.now().day >= dia && (ultimaExec == null ||!ultimaExec.startsWith(mesAtual))) {
        await addLancamento({'valor': r['valor'], 'tipo': r['tipo'], 'categoria_id': r['categoria_id'], 'conta_id': r['conta_id'], 'data': dataVencimento, 'descricao': r['descricao'], 'recorrente_id': r['id']});
        await _db!.update('recorrentes', {'ultima_execucao': hoje}, where: 'id =?', whereArgs: [r['id']]);
      }
    }
  }

  static Future criarCompraParcelada(String desc, double valorTotal, int qtd, String contaId, String catId) async {
    String compraId = uuid.v4();
    await _db!.insert('compras_parceladas', {'id': compraId, 'descricao': desc, 'valor_total': valorTotal, 'qtd_parcelas': qtd, 'data_compra': DateFormat('yyyy-MM-dd').format(DateTime.now()), 'conta_id': contaId, 'categoria_id': catId});
    double valorParcela = valorTotal / qtd;
    DateTime vencimento = DateTime.now();
    for (int i = 1; i <= qtd; i++) {
      await _db!.insert('parcelas', {'id': uuid.v4(), 'compra_id': compraId, 'numero': i, 'valor': valorParcela, 'vencimento': DateFormat('yyyy-MM-dd').format(vencimento), 'paga': 0});
      vencimento = DateTime(vencimento.year, vencimento.month + 1, vencimento.day);
    }
  }

  static Future<List<Map>> getParcelasPendentes() async {
    return await _db!.rawQuery('SELECT p.*, cp.descricao, cp.qtd_parcelas FROM parcelas p LEFT JOIN compras_parceladas cp ON p.compra_id = cp.id WHERE p.paga = 0 ORDER BY p.vencimento');
  }

  static Future pagarParcela(String parcelaId) async {
    var parcela = (await _db!.query('parcelas', where: 'id =?', whereArgs: [parcelaId]))[0];
    var compra = (await _db!.query('compras_parceladas', where: 'id =?', whereArgs: [parcela['compra_id']]))[0];
    await addLancamento({'valor': parcela['valor'], 'tipo': 'SAIDA', 'categoria_id': compra['categoria_id'], 'conta_id': compra['conta_id'], 'data': DateFormat('yyyy-MM-dd').format(DateTime.now()), 'descricao': '${compra['descricao']} - ${parcela['numero']}/${compra['qtd_parcelas']}', 'parcela_id': parcelaId});
    await _db!.update('parcelas', {'paga': 1}, where: 'id =?', whereArgs: [parcelaId]);
  }

  static Future addCorrida(Map data) async {
    data['id'] = uuid.v4();
    await _db!.insert('uber_corridas', data);
  }

  static Future addAbastecimento(Map data) async {
    data['id'] = uuid.v4();
    await _db!.insert('abastecimentos', data);
  }

  static Future<List<Map>> getCorridas() async => await _db!.query('uber_corridas', orderBy: 'data DESC LIMIT 30');
  static Future<List<Map>> getAbastecimentos() async => await _db!.query('abastecimentos', orderBy: 'data DESC LIMIT 10');
}

// ========== TELA PRINCIPAL ==========
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;
  final pages = [const Dashboard(), const LancarPage(), const UberPage(), const MaisPage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.add_circle_outline), selectedIcon: Icon(Icons.add_circle), label: 'Lançar'),
          NavigationDestination(icon: Icon(Icons.local_taxi_outlined), selectedIcon: Icon(Icons.local_taxi), label: 'Uber'),
          NavigationDestination(icon: Icon(Icons.more_horiz), selectedIcon: Icon(Icons.more_horiz), label: 'Mais'),
        ],
      ),
    );
  }
}

// ========== DASHBOARD ==========
class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  double saldoTotal = 0, entradasMes = 0, saidasMes = 0;
  Map<String, double> gastosCategoria = {};
  List<FlSpot> evolucaoSaldo = [];

  @override
  void initState() {
    super.initState();
    carregarDados();
  }

  carregarDados() async {
    var contas = await DB.getContas();
    var lancamentos = await DB.getLancamentosMes();
    evolucaoSaldo = await DB.getEvolucaoSaldo();
    saldoTotal = contas.fold(0, (sum, c) => sum + c['saldo']);
    entradasMes = 0; saidasMes = 0;
    gastosCategoria.clear();
    for (var l in lancamentos) {
      if (l['tipo'] == 'ENTRADA') entradasMes += l['valor'];
      if (l['tipo'] == 'SAIDA' && l['categoria_nome']!= 'Transferência') {
        saidasMes += l['valor'];
        String cat = l['categoria_nome']?? 'Outros';
        gastosCategoria[cat] = (gastosCategoria[cat]?? 0) + l['valor'];
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: RefreshIndicator(
        onRefresh: () async => carregarDados(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Text('Saldo Total', style: TextStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    Text('R\$ ${saldoTotal.toStringAsFixed(2)}', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: saldoTotal >= 0? Colors.green : Colors.red)),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Column(children: [const Text('Entradas', style: TextStyle(fontSize: 12)), Text('R\$ ${entradasMes.toStringAsFixed(2)}', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold))]),
                        Column(children: [const Text('Saídas', style: TextStyle(fontSize: 12)), Text('R\$ ${saidasMes.toStringAsFixed(2)}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))]),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Evolução do Saldo - 6 Meses', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            SizedBox(
              height: 200,
              child: evolucaoSaldo.isEmpty? const Center(child: CircularProgressIndicator())
                : LineChart(LineChartData(
                    gridData: const FlGridData(show: true),
                    titlesData: FlTitlesData(
                      bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (value, meta) {
                        DateTime mes = DateTime.now().subtract(Duration(days: (5 - value.toInt()) * 30));
                        return Text(DateFormat('MMM').format(mes), style: const TextStyle(fontSize: 10));
                      })),
                      leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    borderData: FlBorderData(show: true),
                    lineBarsData: [LineChartBarData(spots: evolucaoSaldo, isCurved: true, color: Colors.blue, barWidth: 3, dotData: const FlDotData(show: true), belowBarData: BarAreaData(show: true, color: Colors.blue.withOpacity(0.2)))],
                  )),
            ),
            const SizedBox(height: 20),
            Text('Gastos do Mês', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            SizedBox(
              height: 220,
              child: gastosCategoria.isEmpty? const Center(child: Text('Sem gastos ainda'))
                : PieChart(PieChartData(sectionsSpace: 2, centerSpaceRadius: 40, sections: gastosCategoria.entries.map((e) => PieChartSectionData(value: e.value, title: '${e.key}\nR\$${e.value.toStringAsFixed(0)}', radius: 60, titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white))).toList())),
            ),
            const SizedBox(height: 20),
            const Center(child: Text('© SS-Tecnologia - (47) 98802-0676', style: TextStyle(fontSize: 12, color: Colors.grey))),
          ],
        ),
      ),
    );
  }
}

// ========== LANÇAR ==========
class LancarPage extends StatefulWidget {
  const LancarPage({super.key});
  @override
  State<LancarPage> createState() => _LancarPageState();
}

class _LancarPageState extends State<LancarPage> {
  final _valor = TextEditingController();
  final _desc = TextEditingController();
  String _tipo = 'SAIDA';
  String? _categoriaId, _contaId;
  List<Map> _contas = [], _categorias = [];

  @override
  void initState() {
    super.initState();
    carregarDados();
  }

  carregarDados() async {
    _contas = await DB.getContas();
    _categorias = await DB.getCategorias();
    if (_contas.isNotEmpty) _contaId = _contas[0]['id'];
    if (_categorias.isNotEmpty) _categoriaId = _categorias[0]['id'];
    setState(() {});
  }

  salvar() async {
    if (_valor.text.isEmpty || _contaId == null || _categoriaId == null) return;
    await DB.addLancamento({'valor': double.parse(_valor.text.replaceAll(',', '.')), 'tipo': _tipo, 'categoria_id': _categoriaId, 'conta_id': _contaId, 'data': DateFormat('yyyy-MM-dd').format(DateTime.now()), 'descricao': _desc.text});
    _valor.clear(); _desc.clear();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lançado com sucesso!')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Novo Lançamento')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<String>(segments: const [ButtonSegment(value: 'SAIDA', label: Text('Saída'), icon: Icon(Icons.arrow_downward)), ButtonSegment(value: 'ENTRADA', label: Text('Entrada'), icon: Icon(Icons.arrow_upward))], selected: {_tipo}, onSelectionChanged: (s) => setState(() => _tipo = s.first)),
          const SizedBox(height: 16),
          TextField(controller: _valor, decoration: const InputDecoration(labelText: 'Valor', prefixText: 'R\$ ', border: OutlineInputBorder()), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(height: 16),
          DropdownButtonFormField(value: _categoriaId, decoration: const InputDecoration(labelText: 'Categoria', border: OutlineInputBorder()), items: _categorias.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['nome']))).toList(), onChanged: (v) => setState(() => _categoriaId = v)),
          const SizedBox(height: 16),
          DropdownButtonFormField(value: _contaId, decoration: const InputDecoration(labelText: 'Conta', border: OutlineInputBorder()), items: _contas.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text('${c['nome']} - R\$ ${c['saldo'].toStringAsFixed(2)}'))).toList(), onChanged: (v) => setState(() => _contaId = v)),
          const SizedBox(height: 16),
          TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Descrição', border: OutlineInputBorder())),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: salvar, icon: const Icon(Icons.save), label: const Text('Salvar Lançamento')),
          const SizedBox(height: 40),
          const Center(child: Text('© SS-Tecnologia - (47) 98802-0676', style: TextStyle(fontSize: 12, color: Colors.grey))),
        ],
      ),
    );
  }
}

// ========== UBER ==========
class UberPage extends StatefulWidget {
  const UberPage({super.key});
  @override
  State<UberPage> createState() => _UberPageState();
}

class _UberPageState extends State<UberPage> {
  final _valor = TextEditingController();
  final _taxa = TextEditingController();
  final _km = TextEditingController();
  final _horas = TextEditingController();
  final _litros = TextEditingController();
  final _kmAtual = TextEditingController();
  final _posto = TextEditingController();
  String? _contaId;
  List<Map> _contas = [];
  double ganhoKm = 0, ganhoHora = 0, consumoMedio = 0, totalMes = 0, custoKm = 0;

  @override
  void initState() {
    super.initState();
    carregarDados();
  }

  carregarDados() async {
    _contas = await DB.getContas();
    if (_contas.isNotEmpty) _contaId = _contas[0]['id'];
    calcularMetricas();
  }

  calcularMetricas() async {
    var corridas = await DB.getCorridas();
    var abastecimentos = await DB.getAbastecimentos();
    double totalGanho = corridas.fold(0, (sum, c) => sum + c['valor_liquido']);
    double totalKm = corridas.fold(0, (sum, c) => sum + c['km']);
    double totalHoras = corridas.fold(0, (sum, c) => sum + c['horas']);
    double totalCombustivel = abastecimentos.fold(0, (sum, a) => sum + a['valor']);
    totalMes = totalGanho;
    ganhoKm = totalKm > 0? totalGanho / totalKm : 0;
    ganhoHora = totalHoras > 0? totalGanho / totalHoras : 0;
    custoKm = totalKm > 0? totalCombustivel / totalKm : 0;
    if (abastecimentos.length >= 2) {
      double kmRodado = abastecimentos[0]['km_atual'] - abastecimentos[1]['km_atual'];
      double litros = abastecimentos[0]['litros'];
      if (litros > 0) consumoMedio = kmRodado / litros;
    }
    setState(() {});
  }

  salvarCorrida() async {
    if (_valor.text.isEmpty || _km.text.isEmpty || _horas.text.isEmpty || _contaId == null) return;
    double bruto = double.parse(_valor.text.replaceAll(',', '.'));
    double taxa = double.parse(_taxa.text.isEmpty? '0' : _taxa.text.replaceAll(',', '.'));
    await DB.addCorrida({'data': DateFormat('yyyy-MM-dd').format(DateTime.now()), 'valor_bruto': bruto, 'taxa_app': taxa, 'valor_liquido': bruto - taxa, 'km': double.parse(_km.text.replaceAll(',', '.')), 'horas': double.parse(_horas.text.replaceAll(',', '.')), 'conta_id': _contaId});
    _valor.clear(); _taxa.clear(); _km.clear(); _horas.clear();
    calcularMetricas();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Corrida salva!')));
  }

  salvarAbastecimento() async {
    if (_valor.text.isEmpty || _litros.text.isEmpty || _kmAtual.text.isEmpty || _contaId == null) return;
    await DB.addAbastecimento({'data': DateFormat('yyyy-MM-dd').format(DateTime.now()), 'litros': double.parse(_litros.text.replaceAll(',', '.')), 'valor': double.parse(_valor.text.replaceAll(',', '.')), 'km_atual': double.parse(_kmAtual.text.replaceAll(',', '.')), 'posto': _posto.text, 'conta_id': _contaId});
    _valor.clear(); _litros.clear(); _kmAtual.clear(); _posto.clear();
    calcularMetricas();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Abastecimento salvo!')));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(title: const Text('Uber'), bottom: const TabBar(tabs: [Tab(text: 'Corrida', icon: Icon(Icons.directions_car)), Tab(text: 'Abastecer', icon: Icon(Icons.local_gas_station))])),
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Column(
                children: [
                  Text('Faturamento Líquido: R\$ ${totalMes.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _MetricaCard('R\$/km', ganhoKm.toStringAsFixed(2)),
                      _MetricaCard('R\$/hora', ganhoHora.toStringAsFixed(2)),
                      _MetricaCard('km/L', consumoMedio.toStringAsFixed(1)),
                      _MetricaCard('Custo/km', 'R\$${custoKm.toStringAsFixed(2)}'),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      DropdownButtonFormField(value: _contaId, decoration: const InputDecoration(labelText: 'Conta de recebimento', border: OutlineInputBorder()), items: _contas.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['nome']))).toList(), onChanged: (v) => setState(() => _contaId = v)),
                      const SizedBox(height: 12),
                      TextField(controller: _valor, decoration: const InputDecoration(labelText: 'Valor bruto R\$', border: OutlineInputBorder()), keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      TextField(controller: _taxa, decoration: const InputDecoration(labelText: 'Taxa do app R\$', border: OutlineInputBorder()), keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      TextField(controller: _km, decoration: const InputDecoration(labelText: 'KM rodado', border: OutlineInputBorder()), keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      TextField(controller: _horas, decoration: const InputDecoration(labelText: 'Horas online', border: OutlineInputBorder()), keyboardType: TextInputType.number),
                      const SizedBox(height: 16),
                      FilledButton.icon(onPressed: salvarCorrida, icon: const Icon(Icons.save), label: const Text('Salvar Corrida')),
                    ],
                  ),
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      DropdownButtonFormField(value: _contaId, decoration: const InputDecoration(labelText: 'Conta de pagamento', border: OutlineInputBorder()), items: _contas.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['nome']))).toList(), onChanged: (v) => setState(() => _contaId = v)),
                      const SizedBox(height: 12),
                      TextField(controller: _valor, decoration: const InputDecoration(labelText: 'Valor total R\$', border: OutlineInputBorder()), keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      TextField(controller: _litros, decoration: const InputDecoration(labelText: 'Litros', border: OutlineInputBorder()), keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      TextField(controller: _kmAtual, decoration: const InputDecoration(labelText: 'KM atual do carro', border: OutlineInputBorder()), keyboardType: TextInputType.number),
                      const SizedBox(height: 12),
                      TextField(controller: _posto, decoration: const InputDecoration(labelText: 'Posto (opcional)', border: OutlineInputBorder())),
                      const SizedBox(height: 16),
                      FilledButton.icon(onPressed: salvarAbastecimento, icon: const Icon(Icons.save), label: const Text('Salvar Abastecimento')),
                    ],
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

class _MetricaCard extends StatelessWidget {
  final String label, valor;
  const _MetricaCard(this.label, this.valor);
  @override
  Widget build(BuildContext context) {
    return Column(children: [Text(label, style: const TextStyle(fontSize: 11)), Text(valor, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))]);
  }
}

// ========== MAIS ==========
class MaisPage extends StatelessWidget {
  const MaisPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mais Opções')),
      body: ListView(
        children: [
          ListTile(leading: const Icon(Icons.account_balance), title: const Text('Contas e Transferências'), subtitle: const Text('Gerenciar contas e transferir saldo'), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContasPage()))),
          ListTile(leading: const Icon(Icons.repeat), title: const Text('Contas Recorrentes'), subtitle: const Text('Aluguel, internet, assinaturas'), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RecorrentesPage()))),
          ListTile(leading: const Icon(Icons.credit_card), title: const Text('Parcelas'), subtitle: const Text('Compras parceladas e pagamento'), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ParcelasPage()))),
          const Divider(),
          const ListTile(leading: Icon(Icons.copyright), title: Text('SS-Tecnologia'), subtitle: Text('(47) 98802-0676')),
        ],
      ),
    );
  }
}

// ========== CONTAS E TRANSFERÊNCIA ==========
class ContasPage extends StatefulWidget {
  const ContasPage({super.key});
  @override
  State<ContasPage> createState() => _ContasPageState();
}

class _ContasPageState extends State<ContasPage> {
  List<Map> _contas = [];
  final _nomeConta = TextEditingController();
  final _valorTransf = TextEditingController();
  String? _origemId, _destinoId;

  @override
  void initState() {
    super.initState();
    carregarContas();
  }

  carregarContas() async {
    _contas = await DB.getContas();
    setState(() {});
  }

  addConta() async {
    if (_nomeConta.text.isEmpty) return;
    await DB.addConta(_nomeConta.text, 'CORRENTE');
    _nomeConta.clear();
    carregarContas();
  }

  transferir() async {
    if (_origemId == null || _destinoId == null || _valorTransf.text.isEmpty) return;
    if (_origemId == _destinoId) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contas devem ser diferentes')));
      return;
    }
    await DB.transferir(_origemId!, _destinoId!, double.parse(_valorTransf.text.replaceAll(',', '.')));
    _valorTransf.clear();
    carregarContas();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transferência realizada!')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contas
