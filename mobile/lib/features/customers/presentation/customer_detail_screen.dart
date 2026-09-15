import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/widgets/async_state_view.dart';
import '../data/customers_providers.dart';

class CustomerDetailScreen extends ConsumerWidget {
  const CustomerDetailScreen({super.key, required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customerAsync = ref.watch(customerDetailProvider(customerId));

    return Scaffold(
      appBar: AppBar(
        title: customerAsync.maybeWhen(data: (c) => Text(c.name), orElse: () => const Text('Müşteri')),
      ),
      body: AsyncStateView(
        value: customerAsync,
        onRetry: () async => ref.invalidate(customerDetailProvider(customerId)),
        data: (context, c) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (c.address.isNotEmpty) ...[
                      const Text('Adres', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      Text(c.address),
                      const SizedBox(height: 12),
                    ],
                    if (c.taxOffice.isNotEmpty || c.taxNumber.isNotEmpty) ...[
                      Text('${c.taxOffice}  ${c.taxNumber}'.trim()),
                      const SizedBox(height: 12),
                    ],
                    if (c.notes.isNotEmpty) Text(c.notes),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (c.phone.isNotEmpty)
              _ActionTile(
                icon: Icons.call_outlined,
                label: c.phone,
                onTap: () => launchUrl(Uri(scheme: 'tel', path: c.phone)),
              ),
            if (c.email.isNotEmpty)
              _ActionTile(
                icon: Icons.email_outlined,
                label: c.email,
                onTap: () => launchUrl(Uri(scheme: 'mailto', path: c.email)),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(leading: Icon(icon), title: Text(label), onTap: onTap),
    );
  }
}
