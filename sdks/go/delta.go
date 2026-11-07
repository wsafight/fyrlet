package fyrlet

import "errors"

const maxItems = 100

var errInvalidDelta = errors.New("invalid subscription delta")

func recordID(value any) (string, map[string]any, bool) {
	record, ok := value.(map[string]any)
	if !ok {
		return "", nil, false
	}
	id, ok := record["id"].(string)
	return id, record, ok
}

func patchList(patch map[string]any, key string) ([]any, error) {
	value, present := patch[key]
	if !present {
		return nil, nil
	}
	list, ok := value.([]any)
	if !ok || len(list) > maxItems {
		return nil, errInvalidDelta
	}
	return list, nil
}

func parseChange(change any) (string, map[string]any, []string, error) {
	parts, ok := change.([]any)
	if !ok || (len(parts) != 2 && len(parts) != 3) {
		return "", nil, nil, errInvalidDelta
	}
	id, ok := parts[0].(string)
	fields, isMap := parts[1].(map[string]any)
	if !ok || !isMap {
		return "", nil, nil, errInvalidDelta
	}
	if _, has := fields["id"]; has {
		return "", nil, nil, errInvalidDelta
	}
	var cleared []string
	if len(parts) == 3 {
		names, ok := parts[2].([]any)
		if !ok {
			return "", nil, nil, errInvalidDelta
		}
		seen := map[string]bool{}
		for _, name := range names {
			key, ok := name.(string)
			if _, set := fields[key]; !ok || key == "id" || set || seen[key] {
				return "", nil, nil, errInvalidDelta
			}
			seen[key] = true
			cleared = append(cleared, key)
		}
	}
	return id, fields, cleared, nil
}

func replaceRecord(previous, fields map[string]any, cleared []string) map[string]any {
	updated := make(map[string]any, len(previous)+len(fields))
	for key, value := range previous {
		updated[key] = value
	}
	for key, value := range fields {
		updated[key] = value
	}
	for _, key := range cleared {
		delete(updated, key)
	}
	return updated
}

// applyDelta applies a compact delta-v1 patch. The input view is never modified.
func applyDelta(data any, patch any) ([]any, error) {
	view, ok := data.([]any)
	changes, isMap := patch.(map[string]any)
	if !ok || !isMap || len(view) > maxItems {
		return nil, errInvalidDelta
	}
	for key := range changes {
		if key != "a" && key != "c" && key != "r" && key != "o" {
			return nil, errInvalidDelta
		}
	}
	records := make(map[string]map[string]any, len(view))
	ids := make([]string, 0, len(view))
	for _, entry := range view {
		id, record, ok := recordID(entry)
		if _, duplicate := records[id]; !ok || duplicate {
			return nil, errInvalidDelta
		}
		records[id] = record
		ids = append(ids, id)
	}
	touched := map[string]bool{}
	touch := func(id string) error {
		if touched[id] {
			return errInvalidDelta
		}
		touched[id] = true
		return nil
	}
	removed, err := patchList(changes, "r")
	if err != nil {
		return nil, err
	}
	for _, value := range removed {
		id, ok := value.(string)
		if _, exists := records[id]; !ok || !exists || touch(id) != nil {
			return nil, errInvalidDelta
		}
		delete(records, id)
	}
	added, err := patchList(changes, "a")
	if err != nil {
		return nil, err
	}
	for _, value := range added {
		id, record, ok := recordID(value)
		if _, exists := records[id]; !ok || exists || touch(id) != nil {
			return nil, errInvalidDelta
		}
		records[id] = record
	}
	updates, err := patchList(changes, "c")
	if err != nil {
		return nil, err
	}
	for _, change := range updates {
		id, fields, cleared, err := parseChange(change)
		previous, exists := records[id]
		if err != nil || !exists || touch(id) != nil {
			return nil, errInvalidDelta
		}
		records[id] = replaceRecord(previous, fields, cleared)
	}
	order := make([]string, 0, len(records))
	if _, has := changes["o"]; has {
		list, err := patchList(changes, "o")
		if err != nil {
			return nil, err
		}
		for _, value := range list {
			id, ok := value.(string)
			if !ok {
				return nil, errInvalidDelta
			}
			order = append(order, id)
		}
	} else {
		order = ids
	}
	seen := map[string]bool{}
	for _, id := range order {
		if _, exists := records[id]; !exists || seen[id] {
			return nil, errInvalidDelta
		}
		seen[id] = true
	}
	if len(records) > maxItems || len(order) != len(records) {
		return nil, errInvalidDelta
	}
	result := make([]any, len(order))
	for position, id := range order {
		result[position] = records[id]
	}
	return result, nil
}
