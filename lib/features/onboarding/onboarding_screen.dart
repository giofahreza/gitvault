import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Initial onboarding screen for first-time setup
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _currentStep = 0;

  final _repoOwnerController = TextEditingController();
  final _repoNameController = TextEditingController();
  final _tokenController = TextEditingController();

  @override
  void dispose() {
    _repoOwnerController.dispose();
    _repoNameController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome to GitVault'),
      ),
      body: Stepper(
        currentStep: _currentStep,
        onStepContinue: _currentStep < 3 ? () => setState(() => _currentStep++) : null,
        onStepCancel: _currentStep > 0 ? () => setState(() => _currentStep--) : null,
        steps: [
          Step(
            title: const Text('Introduction'),
            content: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.security, size: 64, color: Colors.deepPurple),
                SizedBox(height: 16),
                Text(
                  'GitVault is a sovereign password manager',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text('Your data is encrypted on-device and stored in your private GitHub repository.'),
                SizedBox(height: 8),
                Text('GitHub never sees your passwords - only random encrypted data.'),
              ],
            ),
            isActive: _currentStep >= 0,
          ),
          Step(
            title: const Text('GitHub Setup'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Create a private GitHub repository for your vault:'),
                const SizedBox(height: 16),
                TextField(
                  controller: _repoOwnerController,
                  decoration: const InputDecoration(
                    labelText: 'GitHub Username',
                    hintText: 'your-username',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _repoNameController,
                  decoration: const InputDecoration(
                    labelText: 'Repository Name',
                    hintText: 'my-vault',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tokenController,
                  decoration: const InputDecoration(
                    labelText: 'Personal Access Token',
                    hintText: 'ghp_...',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Generate a token at: github.com/settings/tokens',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            isActive: _currentStep >= 1,
          ),
          Step(
            title: const Text('Biometric Setup'),
            content: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.fingerprint, size: 48, color: Colors.deepPurple),
                SizedBox(height: 16),
                Text('Your vault will be protected by biometric authentication.'),
                SizedBox(height: 8),
                Text('No master password needed - your fingerprint or face is the key.'),
              ],
            ),
            isActive: _currentStep >= 2,
          ),
          Step(
            title: const Text('Recovery Kit'),
            content: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning, size: 48, color: Colors.orange),
                SizedBox(height: 16),
                Text(
                  'IMPORTANT: Save your recovery kit!',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text('If you lose all your devices, this is your only way to recover your data.'),
                SizedBox(height: 8),
                Text('Print it and store it in a safe place.'),
              ],
            ),
            isActive: _currentStep >= 3,
          ),
        ],
      ),
    );
  }
}
