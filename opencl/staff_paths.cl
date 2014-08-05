struct path_point {
    float cost;
    int prev;
};

kernel void staff_paths(global const uchar *image,
                        int image_w, int image_h,
                        int staff_thick,
                        float scale,
                        global struct path_point *paths,
                        int paths_w, int paths_h) {
    int worker_id = get_local_id(0);
    int num_workers = get_local_size(0);

    for (int x = 0; x < paths_w; x++) {
        if (x == 0) {
            for (int y = worker_id; y < paths_h; y += num_workers) {
                paths[x + paths_w * y].cost = 0.f;
                paths[x + paths_w * y].prev = -1;
            }
            continue;
        }
        for (int y = worker_id; y < paths_h; y += num_workers) {
            int image_x0 = convert_int_rtn(x * scale);
            int image_y0 = convert_int_rtn(y * scale);
            int image_x1 = convert_int_rtn((x + 1) * scale);
            int image_y1 = convert_int_rtn((y + 1) * scale);
            int looks_like_staff = 0;
            int any_dark = 0;
            for (int image_y = image_y0; image_y < image_y1; image_y++)
                for (int image_x = image_x0; image_x < image_x1; image_x++) {
                    if (! (0 <= image_x && image_x < image_w*8))
                        continue;
                    if (! (0 <= image_y - staff_thick && image_y + staff_thick < image_h))
                        continue;
                    int byte_x = image_x / 8;
                    int bit_x  = image_x % 8;
                    uchar center = image[byte_x + image_w * image_y];
                    uchar above  = image[byte_x + image_w * (image_y-staff_thick)];
                    uchar below  = image[byte_x + image_w * (image_y+staff_thick)];
                    if ((center & ~(above | below)) & (0x80U >> bit_x)) {
                        looks_like_staff = 1;
                        goto LOOKS_LIKE_STAFF;
                    }
                    else if (center & (0x80U >> bit_x))
                        any_dark = 1;
                }
            float base_weight;

            LOOKS_LIKE_STAFF:
            any_dark = 0;
            base_weight = (any_dark ? 4.f : 8.f) - looks_like_staff;
            float prev_cost = INFINITY;
            int prev = 0;
            for (int prev_y = y - 1; prev_y <= y + 1; prev_y++)
                if (0 <= prev_y && prev_y < paths_h) {
                    float old_cost = paths[x-1 + paths_w * prev_y].cost
                                     + ((prev_y == y) ? 0 : 1);
                    if (old_cost < prev_cost) {
                        prev_cost = old_cost;
                        prev = prev_y;
                    }
                }
            paths[x + paths_w * y].cost = prev_cost + base_weight;
            paths[x + paths_w * y].prev = prev;
        }

        // Ensure workers all process the current column before moving on
        // to the next one
        barrier(CLK_GLOBAL_MEM_FENCE);
    }
}

kernel void find_stable_paths(global const struct path_point *paths,
                              int w,
                              global volatile int *stable_path_end) {
    int y1 = get_global_id(0);
    // Initialize stable_path_end
    stable_path_end[y1] = -1;
    barrier(CLK_GLOBAL_MEM_FENCE);

    // Trace back shortest path from (x1, y1)
    int y = y1;
    for (int x = w-1; x > 0; x--)
        y = paths[x + w * y].prev;

    // Update stable_path_end[y] with y1 as long as the path is shorter
    // than the one currently stored there
    float our_cost = paths[w-1 + w * y1].cost;
    int cur_y1;
    do {
        cur_y1 = stable_path_end[y];
        if (cur_y1 >= 0 && paths[w-1 + w * cur_y1].cost >= our_cost)
            break;
    } while (atomic_cmpxchg(&stable_path_end[y], cur_y1, y1) != cur_y1);
}

// stable_path_end must be packed by removing invalid y < 0
kernel void extract_stable_paths(global const struct path_point *paths,
                                 int w,
                                 global const int *stable_path_end,
                                 global int *stable_paths) {
    int path_ind = get_global_id(0);
    int y = stable_path_end[path_ind];
    for (int x = w-1; x >= 0; x--) {
        stable_paths[x + w * path_ind] = y;
        y = paths[x + w * y].prev;
    }
}

kernel void remove_paths(global uchar *image,
                         global const int *stable_paths,
                         int path_num_points, int num_paths,
                         int path_scale) {
    if (path_scale != 2) return; // XXX

    int x = get_global_id(0);
    int y = get_global_id(1);
    int w = get_global_size(0);

    // Check each path to see if it overlaps with this byte
    uchar byte_mask = 0xFFU;
    uchar cur_mask;
    int path_point;
    for (cur_mask = 0xC0U, path_point = x*8 / path_scale;
         cur_mask != 0, path_point < path_num_points;
         cur_mask >>= path_scale, path_point++) {
        int in_path = 0;
        for (int path = 0; path < num_paths; path++) {
            int path_y = stable_paths[path_point + path_num_points * path];
            if (path_y == y / path_scale)
                in_path = 1;
        }
        if (in_path)
            byte_mask &= ~ cur_mask;
    }

    image[x + w * y] &= byte_mask;
}
