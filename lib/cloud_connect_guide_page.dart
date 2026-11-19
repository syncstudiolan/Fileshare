import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'main.dart' show FileTheme, CloudConnectPage;

/// Offline, in-app onboarding: no account identifiers or tokens are collected.
/// This guide mirrors the actual File Share provisioner in cloudflare_provisioning.dart.
class CloudConnectGuidePage extends StatefulWidget {
  const CloudConnectGuidePage({super.key,required this.mode,required this.onMode});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  @override State<CloudConnectGuidePage> createState()=>_CloudConnectGuidePageState();
}

class _CloudGuideStep {
  const _CloudGuideStep(this.title,this.details,{this.link,this.note});
  final String title,details;
  final String? link,note;
}

class _CloudGuideSection {
  const _CloudGuideSection(this.title,this.steps);
  final String title;
  final List<_CloudGuideStep> steps;
}

// Explanations intentionally describe the app as shipped; they do not promise
// Cloudflare free-tier capacity, Google Drive fallback, automatic email OTP,
// account migration, real-time background push or successful external billing.
const _sections=< _CloudGuideSection >[
  _CloudGuideSection('01 · Before you begin',[
    _CloudGuideStep('Understand what will be connected',
      'File Share uses YOUR Cloudflare account: one personal Worker (HTTPS API and guest QR page), a D1 database (login, QR and file records), and a private R2 bucket (uploaded files). The central directory only helps later devices find your personal Worker. Offline LAN does not require a cloud account.'),
    _CloudGuideStep('Prepare a secure account and internet',
      'Use a working internet connection, an email you control, a password manager and access to the Cloudflare dashboard. Keep your phone unlocked during setup. Do NOT send credentials or tokens to anyone over chat or screenshots.'),
    _CloudGuideStep('Sign up / sign in to Cloudflare',
      'Open dash.cloudflare.com and create a Cloudflare account if needed. Complete any Cloudflare email or security verification and open the correct account workspace. This is the Cloudflare account, NOT your later File Share login.',
      link:'https://dash.cloudflare.com/'),
    _CloudGuideStep('Choose free limits carefully',
      'Cloudflare may require payment details to activate R2. Review your account\'s current pricing, Free plan, available quotas and billing alerts BEFORE enabling anything. File Share does not buy a paid plan automatically; usage beyond free allowances may be billed by Cloudflare.',
      link:'https://developers.cloudflare.com/r2/pricing/'),
    _CloudGuideStep('Enable Workers and workers.dev',
      'In Cloudflare Dashboard open Workers & Pages (menu names can change). Activate Workers and choose/confirm your personal workers.dev subdomain. A paid custom domain is not required. If one already exists, reuse it.',
      link:'https://developers.cloudflare.com/workers/configuration/routing/workers-dev/'),
    _CloudGuideStep('Activate Cloudflare R2',
      'Open R2 Object Storage and follow Cloudflare\'s activation screens. Review any billing prompt. The app later creates its own private bucket; you normally do not need to create a bucket yourself. Do not make it public.',
      link:'https://developers.cloudflare.com/r2/get-started/'),
  ]),
  _CloudGuideSection('02 · Get Account ID and secure API token',[
    _CloudGuideStep('Find the Account ID — not Zone ID',
      'In Cloudflare select the correct account. Look for Account details / Account ID on the account dashboard, or the account segment of the dashboard URL. Copy the complete 32-character hexadecimal Account ID. A website Zone ID is DIFFERENT and will not work.',
      link:'https://developers.cloudflare.com/fundamentals/setup/find-account-and-zone-ids/'),
    _CloudGuideStep('Create a restricted token',
      'Cloudflare profile → API Tokens (or Account → API Tokens if available) → Create Token → Create Custom Token. Give it a clear name such as File Share Personal Cloud Setup. Do NOT choose Global API Key, nor an R2 S3 access key. You need a Cloudflare management API token.',
      link:'https://developers.cloudflare.com/fundamentals/api/get-started/create-token/'),
    _CloudGuideStep('Give the exact necessary permissions',
      'Scope the token to your ONE intended Cloudflare account. Include Account: Workers Scripts Edit (or Workers Editor), Account: D1 Edit and Account: Workers R2 Storage Edit (UI labels may show Read/Write). Worker deployment, bindings, worker subdomain settings and cron scheduling may need additional Workers permission options if Cloudflare changes its UI. Choose minimum permissions covering these operations, not All accounts/global privileges.',
      link:'https://developers.cloudflare.com/fundamentals/api/reference/permissions/'),
    _CloudGuideStep('Confirm token resource scope and create',
      'Set Account Resources to the intended account only, review the summary, and Create Token. Copy the generated secret ONCE to a secure temporary location. Cloudflare may not reveal it again. Never save it in a Git repository, screenshots, email or ordinary chat.'),
    _CloudGuideStep('Check an expired/invalid token',
      'If verification returns 401 or 403: check you copied the entire token, did not copy the Token ID, selected the correct account, granted D1/R2/Workers rights, and that the token is active/not expired. Edit or replace the token from Cloudflare if required.'),
  ]),
  _CloudGuideSection('03 · Automatic setup in File Share',[
    _CloudGuideStep('Open Personal Cloud Setup in the app',
      'File Share → Settings → Cloud Setup → Open Cloud Setup. This page contains Cloudflare Account ID, Restricted Cloudflare API Token and Verify & Auto Connect. You can also reach it from the File Share sign-in page.'),
    _CloudGuideStep('Enter Account ID and API token',
      'Paste the 32-character Account ID into its own field. Paste the management API token into the password-style token field. Keep the two values separate; your future Worker owner secret is a DIFFERENT credential.'),
    _CloudGuideStep('Tap Verify & Auto Connect',
      'Tap once and keep the app open until it finishes. The app checks the token, finds or creates its own D1 database and private R2 bucket, applies the bundled D1 schema, deploys a personal Worker and QR guest upload page, configures resource bindings and a private owner secret, enables workers.dev and schedules cleanup.'),
    _CloudGuideStep('Understand what is generated automatically',
      'The app uses the Cloudflare Account ID to derive a unique fileshare-personal-… Worker, D1 database and R2 bucket name. The app securely stores its owner bootstrap secret locally; the API token is cleared after provisioning. An existing Worker without its matching saved owner secret is intentionally NOT overwritten.'),
    _CloudGuideStep('Wait for the actual storage self-test',
      'Successful setup must confirm the Worker D1 and R2 read/write/delete self-test. A newly created workers.dev hostname may need time to propagate. If the app says storage verification failed, fix connectivity or Cloudflare permissions and retry Auto Connect: existing named resources are reused. Do not delete resources at random.'),
    _CloudGuideStep('Create your File Share login',
      'After setup, tap Create account or Login. Register a personal email and strong password with the personal Worker. These are the File Share account credentials, separate from Cloudflare dashboard access. Use your own email consistently; current onboarding does NOT automatically prove mailbox ownership with OTP.'),
    _CloudGuideStep('Link account to Central Directory',
      'When the personal account is authenticated, the app links the verified session and personal Worker URL to its central email directory. This allows another device to locate your Worker using email/password. Your password is verified by your own Worker, NOT saved in Central Directory. A first email-to-Worker link is intentionally permanent; migration/recovery is not automated.'),
    _CloudGuideStep('Confirm cloud connected',
      'In Settings → My profile check Personal Cloudflare status and your Worker URL. Then open My Permanent QR and Generate Permanent QR if it does not already exist. Do not confuse a valid Worker URL with a signed-in account session.'),
  ]),
  _CloudGuideSection('04 · QR and everyday file sharing',[
    _CloudGuideStep('Generate, copy and test your permanent QR',
      'Open My Permanent QR → Generate Permanent QR → Copy Link or Share QR. Scan it in a separate device browser. The browser guest page should load over HTTPS and allow selecting files. QR remains until you revoke or regenerate it.'),
    _CloudGuideStep('Test a guest upload end-to-end',
      'Upload one small safe test file through the QR guest page and finish the upload. Return to File Share cloud inbox on your approved/signed-in device; refresh or reopen if needed. Confirm filename and actual download. Guest browser limits in this version are 200 MB total and four upload sessions per guest per IST day.'),
    _CloudGuideStep('Understand expiry and background notifications',
      'Guest temporary cloud files expire around midnight IST; periodic cleanup and retries may execute later than exactly 00:00. Downloads saved to your phone are separate. Guest upload event notifications are intended for the foreground; after backgrounding the app, reopening/refreshing recovers missed items.'),
    _CloudGuideStep('Sign in on your second device',
      'Install File Share on another device. Enter the SAME File Share email/password. When linked, the Central Directory locates the personal Worker and your Worker authenticates the login. If it says email not registered, ensure the FIRST device completed personal-cloud account linking.'),
    _CloudGuideStep('Keep offline sharing independent',
      'LAN/Offline sending can work on the same local Wi-Fi without personal cloud login. Cloudflare online upload needs working internet and an authenticated personal Worker account. Cloud and LAN cards appear in the unified File Share dashboard.'),
  ]),
  _CloudGuideSection('05 · Advanced setup, maintenance and recovery',[
    _CloudGuideStep('Use an existing personal Worker (advanced)',
      'Only if you already own a compatible File Share Worker with D1, private R2 binding and OWNER_TOKEN: Settings → Open Cloud Setup → Connect your own Cloudflare Worker. Enter the full HTTPS *.workers.dev URL and its OWNER secret, then Verify & Connect. This owner secret is NOT the Cloudflare management API token.'),
    _CloudGuideStep('Existing Worker error is intentional',
      'If Auto Connect says an existing Worker has no matching saved setup key, STOP. Do not overwrite it or generate a new owner secret. Recover the correct owner secret from your secure device backup or connect manually. A different secret can lock you out or disconnect existing clients.'),
    _CloudGuideStep('Check Worker/D1/R2 resources in Cloudflare',
      'Advanced: Cloudflare Dashboard → Workers & Pages shows your personal Worker and hostname; D1 shows its database; R2 shows its private bucket. Confirm all three belong to YOUR chosen account. Do not change resource bindings or delete D1/R2 while files/accounts are in use.'),
    _CloudGuideStep('Token rotation and secret handling',
      'After initial provisioning, File Share clears the API token from the form. You may revoke a temporary setup token after you confirm everything works; for future Auto Connect upgrades you will need a new restricted token. Preserve your owner secret and login recovery information securely.'),
    _CloudGuideStep('Recover from lost phone / reinstall',
      'Secure account and Worker backups matter: losing the saved OWNER_TOKEN may prevent automatic re-provisioning of an existing Worker. A second device may still log in via the linked email/password if that Worker is live. Automatic account migration and password recovery are NOT implemented in this app.'),
    _CloudGuideStep('Stop, disconnect or revoke QR',
      'Disconnect stored cloud account removes the connection from this device, not Cloudflare files. Sign out stops the active session but keeps offline LAN. Revoke/Regenerate in My Permanent QR invalidates the old guest link. To delete data or services permanently, review Cloudflare resources carefully first.'),
    _CloudGuideStep('Diagnose a setup or network error',
      '400 Account ID: must be 32 hex characters, not Zone ID. 401/403: wrong, expired or insufficient API token. 404 on Worker: check workers.dev subdomain/hostname. D1 schema error: inspect D1 permissions and Worker binding. R2 error: activate R2 and verify bucket rights. Timeout: internet, DNS, Worker deployment propagation and account quotas. Retry only after identifying the failed stage.'),
    _CloudGuideStep('Understand limits and costs',
      'Cloudflare Workers requests, D1 reads/writes and R2 storage/operations use your own account quotas and may change. Review Cloudflare billing, usage and current pricing regularly. Never claim uploads are unlimited or that a paid plan is automatically enabled.'),
    _CloudGuideStep('Official reference material',
      'Use current Cloudflare documentation if dashboard names or permissions have changed. Workers, R2, D1 and API token links appear throughout this guide. This in-app guide is not a substitute for live Cloudflare plan/permission screens.',
      link:'https://developers.cloudflare.com/'),
  ]),
];

class _CloudConnectGuidePageState extends State<CloudConnectGuidePage> {
  final Set<String> _checked=<String>{};
  int _tab=0;
  @override Widget build(BuildContext context) {
    final allCount=_sections.fold<int>(0,(total,s)=>total+s.steps.length);
    return Scaffold(
      appBar:AppBar(title:const Text('Cloud Connect Guide')),
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:SafeArea(child:Center(child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:850),
          child:Column(children:[
            Padding(padding:const EdgeInsets.fromLTRB(14,10,14,0),
              child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                const Text('Your Cloudflare, step by step',
                  style:TextStyle(fontWeight:FontWeight.w800,fontSize:19)),
                const SizedBox(height:5),
                Text('${_checked.length} of $allCount guide steps checked. '
                  'No secret is stored in this guide.',
                  style:const TextStyle(fontSize:12)),
                LinearProgressIndicator(value:_checked.length/allCount),
                const SizedBox(height:12),
                SingleChildScrollView(scrollDirection:Axis.horizontal,
                  child:Row(children:[for(var i=0;i<_sections.length;i++)
                    Padding(padding:const EdgeInsets.only(right:7),
                      child:ChoiceChip(label:Text(_sections[i].title),
                        selected:i==_tab,
                        onSelected:(_)=>setState(()=>_tab=i))),
                  ])),
              ])),
            Expanded(child:ListView(
              key:ValueKey(_tab),
              padding:const EdgeInsets.all(14),
              children:[
                for(var i=0;i<_sections[_tab].steps.length;i++)
                  _stepCard(_sections[_tab].steps[i],_tab,i),
                const SizedBox(height:12),
                FilledButton.icon(
                  onPressed:()=>Navigator.push(context,MaterialPageRoute<void>(
                    builder:(_)=>CloudConnectPage(
                      mode:widget.mode,onMode:widget.onMode))),
                  icon:const Icon(Icons.cloud_sync_outlined),
                  label:const Text('Open actual Cloud Setup')),
                const SizedBox(height:8),
                Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
                  TextButton(onPressed:_tab==0?null:
                    ()=>setState(()=>_tab--),child:const Text('Previous')),
                  TextButton(onPressed:_tab==_sections.length-1?null:
                    ()=>setState(()=>_tab++),child:const Text('Next section')),
                ]),
              ])),
          ]),
        ))),
      ),
    );
  }

  Widget _stepCard(_CloudGuideStep step,int group,int index){
    final key='$group:$index';
    return Card(
      margin:const EdgeInsets.only(bottom:9),
      child:ExpansionTile(
        key:PageStorageKey(key),
        leading:Checkbox(value:_checked.contains(key),onChanged:(value){
          setState((){
            if(value==true)_checked.add(key);else _checked.remove(key);
          });
        }),
        title:Text('${index+1}. ${step.title}',
          style:const TextStyle(fontWeight:FontWeight.w600,fontSize:14)),
        children:[Padding(
          padding:const EdgeInsets.fromLTRB(17,0,17,16),
          child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Text(step.details,style:const TextStyle(height:1.5)),
            if(step.note!=null)Text(step.note!),
            if(step.link!=null)...[
              const SizedBox(height:9),
              SelectableText(step.link!,style:const TextStyle(fontSize:12)),
              Align(alignment:Alignment.centerLeft,
                child:TextButton.icon(
                  onPressed:(){
                    Clipboard.setData(ClipboardData(text:step.link!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content:Text('Official documentation URL copied')));
                  },
                  icon:const Icon(Icons.copy_outlined,size:16),
                  label:const Text('Copy official help URL'))),
            ],
          ])),
        ],
      ),
    );
  }
}
