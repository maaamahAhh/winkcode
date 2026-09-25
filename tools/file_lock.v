module tools

import sync

// init_file_lock pre-allocates the file mutation mutex during single-threaded startup,
// ensuring zero data race when background tool worker threads call lock_file_mutation().
pub fn init_file_lock() {
	get_file_mutation_lock()
}

fn get_file_mutation_lock() &sync.Mutex {
	unsafe {
		mut static mu := &sync.Mutex(nil)
		if mu == nil {
			mu = sync.new_mutex()
		}
		return mu
	}
}

pub fn lock_file_mutation() {
	mut mu := get_file_mutation_lock()
	mu.lock()
}

pub fn unlock_file_mutation() {
	mut mu := get_file_mutation_lock()
	mu.unlock()
}
