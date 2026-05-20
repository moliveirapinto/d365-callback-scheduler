# PHP bridge

Single-file drop-in. Works on any PHP 7.4+ webserver: shared hosting, cPanel,
WordPress, Drupal, plain LAMP, Laravel, Symfony, etc. **Only requires the
built-in `curl` and `json` extensions** (enabled by default on virtually every
PHP install).

## Install

1. Upload `book.php` to your web root (e.g. `public_html/`, `htdocs/`, or under
   `wp-content/` for WordPress). Pick whatever path you want the endpoint to
   live at — it will be reachable at that URL.

2. Set 4 environment variables. **How** depends on your hosting:

   **Shared hosting / cPanel** — use the "Environment Variables" or "PHP
   selector" panel. Add each variable, save, restart PHP if asked.

   **Plain Apache** — add to your `.htaccess` next to `book.php`:
   ```apache
   SetEnv DV_ORG_URL https://yourorg.crm.dynamics.com
   SetEnv AAD_TENANT_ID 00000000-0000-0000-0000-000000000000
   SetEnv AAD_CLIENT_ID 00000000-0000-0000-0000-000000000000
   SetEnv AAD_CLIENT_SECRET your-secret-value
   SetEnv DV_PROACTIVE_CONFIG_ID 00000000-0000-0000-0000-000000000000
   SetEnv ALLOWED_ORIGIN https://www.your-site.com
   ```
   ⚠️ Keep the `.htaccess` out of source control if your hosting deploys via
   git. Or use Apache `SetEnvIf` in your vhost config instead so the secret
   never sits in the web root.

   **nginx + php-fpm** — set them in your php-fpm pool config:
   ```ini
   env[DV_ORG_URL] = https://yourorg.crm.dynamics.com
   env[AAD_TENANT_ID] = ...
   env[AAD_CLIENT_ID] = ...
   env[AAD_CLIENT_SECRET] = ...
   env[DV_PROACTIVE_CONFIG_ID] = ...
   env[ALLOWED_ORIGIN] = https://www.your-site.com
   ```
   Restart php-fpm.

   **WordPress** — easiest path is `.htaccess` above. Alternative: put a
   `mu-plugin` that calls `putenv()` from `wp-config.php` before `book.php`
   runs. Don't put secrets in `wp-config.php` if your repo is public.

3. Visit `https://your-site.com/book.php` — you should get `{"error":"POST only"}`.
   That confirms the file is reachable.

4. Open one of the templates from `../../templates/` on your site with
   `?api=` pointing at the bridge URL:
   ```
   https://your-site.com/book-a-call.html?api=https://your-site.com/book.php
   ```

## WordPress integration tip

If you prefer to expose the bridge as a proper WordPress REST route at
`/wp-json/callback/v1/book`, wrap `book.php` in a tiny mu-plugin:

```php
<?php
// wp-content/mu-plugins/callback-bridge.php
add_action('rest_api_init', function () {
    register_rest_route('callback/v1', '/book', [
        'methods'  => 'POST',
        'permission_callback' => '__return_true',
        'callback' => function () {
            require __DIR__ . '/../../path/to/book.php';
            exit;
        },
    ]);
});
```

## Notes

- Token cache lives in `sys_get_temp_dir()`. On shared hosting it may be cleared
  often — that's fine, the bridge just re-acquires a token.
- The naive per-IP rate limit also lives in `sys_get_temp_dir()`. For
  multi-server deployments use APCu / Redis / Memcached instead.
- The bridge does NOT log payloads (only contact id + delivery id) so PII does
  not end up in your access logs.
