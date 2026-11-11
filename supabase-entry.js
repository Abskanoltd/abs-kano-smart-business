import { createClient } from '@supabase/supabase-js';

// Preserve the existing app's window.supabase.createClient interface.
window.supabase = { createClient };
