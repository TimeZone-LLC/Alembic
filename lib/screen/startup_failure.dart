import 'package:alembic/ui/alembic_ui.dart';
import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart';

class StartupFailure extends StatelessWidget {
  final String error;

  const StartupFailure({super.key, required this.error});

  @override
  Widget build(BuildContext context) => ArcaneApp(
        debugShowCheckedModeBanner: false,
        title: 'Alembic',
        theme: const ArcaneTheme(
          scheme: AlembicShadcnTokens.scheme,
          surfaceEffect: StaticSurfaceEffect(),
          backupSurfaceEffect: StaticSurfaceEffect(),
        ),
        home: Builder(
            builder: (BuildContext context) => AlembicScaffold(
                  child: Center(
                      child: SingleChildScrollView(
                          child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: AlembicPanel(
                        child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Icon(LucideIcons.triangleAlert, size: 28),
                        const Gap(16),
                        const AlembicPageHeader(
                            title: 'Alembic could not start'),
                        const Gap(12),
                        const Text(
                            'Close any other Alembic instance and try again. If this continues, retain your Alembic data folder and use the details below to investigate.'),
                        const Gap(16),
                        SelectableText(error),
                        const Gap(20),
                        AlembicToolbarButton(
                          label: 'Copy details',
                          leadingIcon: LucideIcons.copy,
                          onPressed: () =>
                              Clipboard.setData(ClipboardData(text: error)),
                        ),
                      ],
                    )),
                  ))),
                )),
      );
}
