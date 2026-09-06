module tools

import sync

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
