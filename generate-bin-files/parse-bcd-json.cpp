// (c) 2026 Taylor Plewe
// 
// Parses MDN's browser-compat-data JSON file and generate small binary files for use with the canipls language server (https://github.com/taylorplewe/canipls).
// These binary files contain global browser support data for most HTML, CSS & JavaScript features. They were designed to be extremely compact and efficient for the parsing that canipls will be doing.
// The browser usage data is retrieved from caniuse.com's own browser usage table: https://caniuse.com/usage-table. This parsing is done in `parse-caniuse-support-html.cpp`.
//
// minimum canipls version: 0.0.3
//
// binary file format is as follows:
//  1. header section: 4 bytes
//   1.1. u32: minimum canipls version compatible with this format
//   1.2. u32: # total features in this file
//   1.3. u32: # top-level features in this file
//   1.4. u32: (reserved for future use)
//  2.       f32[] section - support %'s
//  3.       u32[] section - ciu ID addr's
//  4.       u32[] section - (reserved for future use)
//  6.       u32[] section - index of first child
//  5.       u16[] section - # of children for this feature
//  7.        u8[] section - tree-sitter syntax node type
//  8.    u8[32][] section - identifier names
//  9. (unaligned) section - ciu ID's
// the reserved sections are an attempt to future-proof the format a bit; I can fill in new features in those sections without incrementing `min_canipls_version`.


// c++ stl
#include <algorithm>
#include <fstream>
#include <ios>
#include <iostream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

// c stl
#include <cassert>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// unix
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// global
#include <simdjson.h>

// local
#include "caniuse.hpp"


#define SIMD_VECTOR_SIZE 16
#define STRING_PADDING_WIDTH 32
#define BCD_DATA_PATH "../bcd-data.json"

#define SIZEOF_SUPPORT_SECTION_ENTRY sizeof(float)
#define SIZEOF_IDENTIFIER_SECTION_ENTRY STRING_PADDING_WIDTH
#define SIZEOF_CIU_ID_ADDRS_SECTION_ENTRY sizeof(uint32_t)


typedef union {
  float version;
  bool  is_added;
  bool  is_invalid;
} VersionAdded;
struct BcdSupportVersion {
  std::string  browser_id;
  VersionAdded version_added;
};

void build_feature_tree_from_bcd_json();
void write_bin_files();
void write_string(std::ofstream&, const char*, int);
void write_string_padded(std::ofstream&, char*, int);
VersionAdded get_version_added_from_browser_support_value(simdjson::ondemand::value&);

#define ZEROES_LEN 2048
char* zeroes = (char[ZEROES_LEN]){0};

// little-endian, but I want it to appear in a hex viewer as [major minor patch]
//                                    patch        minor      major
const uint32_t min_canipls_version = (5  << 16) | (0  << 8) | 0;

enum struct TsNodeKind {
  HtmlTag,
  HtmlAttribute,
  HtmlStringLiteral,

  CssProperty,
  CssAtRule,
  CssSelector,
  CssTagName,
  CssPlainValue,
  CssCallExpression,
  CssMediaStatement,
  CssSupportsStatement,
  CssImportStatement,
  CssFeatureName,
  CssUniversalSelector, // "*"

  JsIdentifier,
  JsPropertyIdentifier,
  JsPrototypePropertyIdentifier,
};
enum struct BinSection {
  Support,
  CiuIdAddr,
  Reserved,
  FirstChildIndex,
  NumChildren,
  TreeSitterSyntaxNodeType,
  Identifier,

  Count,
};
struct CiuFeature {
  std::string             identifier;
  std::string             ciu_id;
  float                   support;
  TsNodeKind              type;
  uint32_t                index_in_bin_file;
  std::vector<CiuFeature> children;
};
struct OutBinInfo {
  std::string             file_path;
  std::ofstream*          stream;
  size_t                  section_pos[static_cast<unsigned long long>(BinSection::Count)];
  size_t                  num_features_total;
  size_t                  num_features_toplevel;
  size_t                  num_features_so_far;
  std::vector<CiuFeature> features;
};
std::unordered_map<TsNodeKind, OutBinInfo> out_bins;

Caniuse::BrowserSupportMap support_map;

int main(int argc, char** argv) {
  Caniuse::VersionMapAllocator version_map_allocator;

  Caniuse::parse_caniuse_support_html_and_fill_support_map(&support_map, version_map_allocator);
  // Caniuse::print_support_map(&support_map);

  out_bins = {
    {TsNodeKind::HtmlTag,       {"out/html_tags.bin",       nullptr}},
    {TsNodeKind::HtmlAttribute, {"out/html_attributes.bin", nullptr}},
    {TsNodeKind::CssProperty,       {"out/css_props.bin",       nullptr}},
    {TsNodeKind::CssAtRule,     {"out/css_at_rules.bin",    nullptr}},
    {TsNodeKind::CssSelector,   {"out/css_selectors.bin",   nullptr}},
    {TsNodeKind::JsIdentifier,  {"out/js_identifiers.bin",  nullptr}},
  };

  for (auto& pair : out_bins) {
    pair.second.stream = new std::ofstream(pair.second.file_path);
  }

  // first, count how many features there are
  build_feature_tree_from_bcd_json();

  // prepare each bin file
  for (auto& pair : out_bins) {
    std::cout << "num total features in " << pair.second.file_path << ": " << pair.second.num_features_total << std::endl;
    std::cout << "num toplevel features in " << pair.second.file_path << ": " << pair.second.num_features_toplevel << std::endl;

    const int header_len = 4 * sizeof(uint32_t);

    const size_t section_lens[static_cast<unsigned long long>(BinSection::Count)] = {
      pair.second.num_features_total * sizeof(float),        // support
      pair.second.num_features_total * sizeof(uint32_t),     // ciu_id_addrs
      pair.second.num_features_total * sizeof(uint32_t),     // reserved
      pair.second.num_features_total * sizeof(uint32_t),     // first_child_idx
      pair.second.num_features_total * sizeof(uint16_t),     // num_children
      pair.second.num_features_total * sizeof(uint8_t),      // type
      pair.second.num_features_total * STRING_PADDING_WIDTH, // identifier
    };

    int total_amount_to_zero = 0;
    for (auto section_len : section_lens) {
      total_amount_to_zero += section_len;
    }

    std::ofstream* out = pair.second.stream;
    // see "binary file format" section at the top of this file
    // header section
    out->write((char*)&min_canipls_version, 4);
    out->write((char*)&pair.second.num_features_total, 4);
    out->write((char*)&pair.second.num_features_toplevel, 4);
    out->write(zeroes, 4); // reserved

    // make space for other sections
    for (int i = 0; i + ZEROES_LEN < total_amount_to_zero; i += ZEROES_LEN) {
      out->write(zeroes, ZEROES_LEN);
    }
    if (total_amount_to_zero % ZEROES_LEN != 0) {
      out->write(zeroes, total_amount_to_zero % ZEROES_LEN);
    }

    // set write positions of each section in each file
    for (int i = 0; i < (int)BinSection::Count; i++) {
      if (i == 0) pair.second.section_pos[i] = header_len;
      else pair.second.section_pos[i] = pair.second.section_pos[i - 1] + section_lens[i - 1];
    }
  }

  // actually add to the files
  write_bin_files();

  for (auto& pair : out_bins) {
    pair.second.stream->close();
  }
}

CiuFeature* get_ciu_feature_from_compat_object(
  simdjson::ondemand::object& compat_obj,
  std::vector<std::string> bcd_level_names_lower,
  std::string last_key,
  CiuFeature* parent_feature
) {
  // build a lowest-version-added-per-browser map for this feature from the BCD data
  std::vector<BcdSupportVersion> support;
  bool is_js = bcd_level_names_lower[0] == "js";
  bool is_js_prototype = false;
  for (auto compat_field : compat_obj) {
    std::basic_string_view<char> compat_field_key = compat_field.unescaped_key();
    if (compat_field_key == "support") {
      simdjson::ondemand::object support_obj = compat_field.value();
      for (auto support_obj_field : support_obj) {
        auto browser_id = std::string(support_obj_field.unescaped_key().value());
        if (support_map.contains(browser_id)) {
          auto browser_field = support_obj_field.value();

          VersionAdded version_added = get_version_added_from_browser_support_value(browser_field.value());
          if (!version_added.is_invalid) {
            support.push_back({.browser_id = browser_id, .version_added = version_added});
          }
        }
      }
    } else if (compat_field_key == "spec_url" && is_js) {
      // some `spec_url`s are arrays with multiple strings (e.g. `Date` > `toLocaleDateString`)
      auto spec_url_str = compat_field.value().get_string();
      if (!spec_url_str.has_value()) {
        simdjson::ondemand::array spec_url_arr = compat_field.value().get_array();
        spec_url_str = spec_url_arr.at(0).get_string();
      }
      is_js_prototype = spec_url_str.value().contains(".prototype.");
    }
  }

  // get corresponding ofstream based on tree sitter syntax node type
  OutBinInfo* out_bin_info = nullptr;
  TsNodeKind type;
  if (bcd_level_names_lower[0] == "html") {
    if (bcd_level_names_lower[1] == "elements") {
      out_bin_info = &out_bins[TsNodeKind::HtmlTag];
      if (bcd_level_names_lower.size() == 3)
        type = TsNodeKind::HtmlTag; // <input>
      else {
        if (last_key.contains('_')) return nullptr;
        if (bcd_level_names_lower.size() == 4)
          type = TsNodeKind::HtmlAttribute; // <input commandfor>
        else
          type = TsNodeKind::HtmlStringLiteral;
      }
    } else if (bcd_level_names_lower[1] == "global_attributes") {
      out_bin_info = &out_bins[TsNodeKind::HtmlAttribute];
      if (bcd_level_names_lower.size() == 3)
        type = TsNodeKind::HtmlAttribute; // <el autofocus>
      else {
        if (last_key.contains('_')) return nullptr;
        type = TsNodeKind::HtmlStringLiteral; // <p contenteditable="plaintext-only">
      }
    }
  } else if (bcd_level_names_lower[0] == "css") {
    if (bcd_level_names_lower[1] == "at-rules") {
      out_bin_info = &out_bins[TsNodeKind::CssAtRule];
      if (bcd_level_names_lower.size() == 3) {
        if (last_key == "import")
          type = TsNodeKind::CssImportStatement;
        else if (last_key == "media")
          type = TsNodeKind::CssMediaStatement;
        else if (last_key == "supports")
          type = TsNodeKind::CssSupportsStatement;
        else
          type = TsNodeKind::CssAtRule;
      } else {
        if (last_key.contains('_')) return nullptr;
        // TODO: @container has fun stuff like `scroll-state_queries` which probably requires specific syntax
        // TODO: @supports has specific syntax stuff like `selector()`
        if (bcd_level_names_lower[2] == "font-feature-values") {
          type = TsNodeKind::CssAtRule;
        } else if (bcd_level_names_lower[2] == "page") {
          if (last_key == "size" || last_key == "page-orientation")
            type = TsNodeKind::CssProperty;
          else
            type = TsNodeKind::CssAtRule;
        } else {
          if (bcd_level_names_lower[2] == "font-face" && std::isupper(last_key[0])) return nullptr;
          type = TsNodeKind::CssProperty;
        }
      }
    } else if (bcd_level_names_lower[1] == "selectors") {
      out_bin_info = &out_bins[TsNodeKind::CssSelector];
      // all of the following A. have their own unique syntax, and B. have high support, so imma just not worry about em for v1
      if (bcd_level_names_lower.size() == 3) {
        if (
          last_key == "type"
          || last_key == "universal"
          || last_key == "id"
          || last_key == "class"
          || last_key == "attribute"
          || last_key == "child"
          || last_key == "next-sibling"
          || last_key == "subsequent-sibling"
          || last_key == "descendant"
          || last_key == "namespace"
          || last_key == "nesting"
        ) return nullptr;
        type = TsNodeKind::CssSelector;
      } else {
        if (bcd_level_names_lower[2] == "scroll-button") {
          if (last_key == "star") type = TsNodeKind::CssUniversalSelector;
          else type = TsNodeKind::CssTagName;
        } else if (bcd_level_names_lower[2] == "selection") {
          type = TsNodeKind::CssProperty;
        } else return nullptr;
      }
    } else if (bcd_level_names_lower[1] == "properties") {
      out_bin_info = &out_bins[TsNodeKind::CssProperty];
      if (bcd_level_names_lower.size() == 3)
        type = TsNodeKind::CssProperty;
      else {
        if (last_key.contains('_')) return nullptr; // the BCD JSON CSS property children sometimes have "contexts" or more abstract features, but actual identifier property values use "-" as space
        type = TsNodeKind::CssPlainValue;
        // NOTE: `shape-outside`s children are almost all functions()
      }
    }
  } else if (bcd_level_names_lower[0] == "javascript") {
    if (bcd_level_names_lower[1] == "builtins") {
      out_bin_info = &out_bins[TsNodeKind::JsIdentifier];
      if (bcd_level_names_lower.size() == 3)
        type = TsNodeKind::JsIdentifier;
      else {
        if (last_key.starts_with("@@") || last_key.contains('_')) return nullptr;
        // NOTE: JS is especially tricky because a lot of these Builtin features refer to methods you can call on *instances* of these types, not the types themselves;
        // e.g. there is no `Array.every()` function, but there is `myNumbers.every()`.
        // there is no way to tell that the symbol `myNumbers` is an instance of `Array` just from syntax alone...
        // best I can do is just make it so users can type `Array.prototype.every` and get support info from that :/
        type = is_js_prototype
          ? TsNodeKind::JsPrototypePropertyIdentifier
          : TsNodeKind::JsPropertyIdentifier;
      }
    }
  } else if (bcd_level_names_lower[0] == "api") {
    out_bin_info = &out_bins[TsNodeKind::JsIdentifier];
    if (bcd_level_names_lower.size() == 2)
      type = TsNodeKind::JsIdentifier;
    else {
      type = TsNodeKind::JsPrototypePropertyIdentifier;
      if (last_key.starts_with("@@")) return nullptr;
      if (last_key.ends_with("_static")) {
        type = TsNodeKind::JsPropertyIdentifier;
        last_key = last_key.substr(0, last_key.size() - 7); // 7 = strlen("_static"), I don't want to add an extra import
      }
      else if (last_key.contains('_')) return nullptr;
    }
  }
  if (out_bin_info == nullptr) return nullptr;

  std::ofstream* out = out_bin_info->stream;

  out_bin_info->num_features_total++;
  if (parent_feature == nullptr)
    out_bin_info->num_features_toplevel++;

  // calculate global support % based off of CanIUse browser support table values (calculated in `gen-caniuse-support-html.cpp`)
  float global_support = 0.0f;
  for (auto version : support) {
    if (version.version_added.version) {
      for (auto ciu_version : support_map[version.browser_id]) {
        if (version.version_added.version <= ciu_version.version) {
          global_support += ciu_version.total_percentage_from_here;
          break;
        }
      }
    }
  }

  // DEBUG: print support table
  // std::cout << last_key << std::endl;
  // for (auto version : support) {
  //   if (version.version_added.version) {
  //     std::cout << version.browser_id << ": " << version.version_added.version << std::endl;
  //   } else {
  //     std::cout << version.browser_id << ": " << version.version_added.is_added << std::endl;
  //   }
  // }
  // std::cout << std::endl;

  // build caniuse feature ID
  auto ciu_feature_id = std::string(); // NOTE: I am excluding the "mdn-" prefix from all these caniuse IDs. The language server can easily prepend that.
  for (int i = 0; i < bcd_level_names_lower.size(); i++) {
    if (i > 0) {
      ciu_feature_id.push_back('_');
    }
    ciu_feature_id.append(bcd_level_names_lower.at(i));
  }
  // std::cout << ciu_feature_id << std::endl;

  // DEBUG
  // if (!is_temporal_found && out_bin_info->file_path == "js_identifiers.bin")
  //   printf("%-32s%2.2f%% index: %zu\n", last_key.c_str(), global_support, out_bin_info->num_features_so_far);

  CiuFeature feature = {
    .identifier = last_key,
    .ciu_id = ciu_feature_id,
    .support = global_support,
    .type = type,
    .children = std::vector<CiuFeature>()
  };
  if (parent_feature == nullptr) {
    out_bin_info->features.push_back(feature);
    return &out_bin_info->features.back();
  } else {
    parent_feature->children.push_back(feature);
    return &parent_feature->children.back();
  }
}

bool is_temporal_found = false;
/// given a JSON object, presumably a subsection of MDN's browser-compat-data, append all features downstream of here with __compat entries to the output file
void append_bcd_feature_tree(
  std::vector<std::string> bcd_level_names_lower,
  simdjson::ondemand::object& obj,
  std::string last_key,
  CiuFeature* parent_feature
) {
  // TEMP
  if (last_key.size() > STRING_PADDING_WIDTH) { // do NOT including tailing 0
    return;
  }

  CiuFeature* feature = nullptr;

  // first, look at this object's `__compat` field
  auto maybe_compat = obj["__compat"];
  if (maybe_compat.has_value()) {
    simdjson::ondemand::object compat_obj = maybe_compat.value();
    feature = get_ciu_feature_from_compat_object(compat_obj, bcd_level_names_lower, last_key, parent_feature);
    if (feature == nullptr) return;
  }
  obj.reset(); // simdjson docs discourage the use of `reset()` but because the `__compat` object AND the feature's children live in the same object, this is necessary. `__compat` must be processed before the children.

  // then, process this feature's children
  for (auto field : obj) {
    std::basic_string_view<char> id = field.unescaped_key();
    auto sub_obj = field.value().get_object();
    if (sub_obj.has_value() && id != "__compat") {
      // keep traversing down the tree
      auto new_level_names_lower = bcd_level_names_lower;
      new_level_names_lower.push_back(std::basic_string<char>(id));
      std::transform(
        new_level_names_lower.back().cbegin(),
        new_level_names_lower.back().cend(),
        new_level_names_lower.back().begin(),
        [](int c){
          return c == '@'
            ? '-'
            : c >= 'A' && c <= 'Z'
              ? c + ('a' - 'A') // 0x20
              : c;
        }
      );
      append_bcd_feature_tree(
        new_level_names_lower,
        sub_obj.value(),
        std::string(id),
        feature
      );
    }
  }
}
void build_feature_tree_from_bcd_json() {
  auto json = simdjson::padded_string::load(BCD_DATA_PATH);
  if (json.error()) {
    std::cout << "ERROR: couldn't open MDN BCD file" << json.error() << std::endl;
  }

  simdjson::ondemand::parser parser;
  simdjson::ondemand::document doc = parser.iterate(json);
  auto doc_obj = doc.get_object().value();

  std::vector<std::string> bcd_level_names_lower;
  append_bcd_feature_tree(
    bcd_level_names_lower,
    doc_obj,
    "",
    nullptr
  );
}

VersionAdded get_version_added_float_from_object(simdjson::ondemand::object& version_added_object) {
  auto version_added_val = version_added_object["version_added"];
  if (version_added_val.has_value()) {
    if (version_added_val.get_bool().has_value()) {
      return {.is_added = version_added_val.get_bool().value()};
    } else if (version_added_val.get_string().has_value()) {
      // coerce string value into float
      std::string_view version_added_str = version_added_val.get_string();
      if (version_added_str.starts_with("≤")) {
        version_added_str.remove_prefix(strlen("≤"));
      } else if (version_added_str == "preview") {
        return { .version = 9999.0 };
      }
      return {.version = std::stof(version_added_str.data())};
    }
  }
  return {.is_invalid = true};
}

VersionAdded get_version_added_from_browser_support_value(simdjson::ondemand::value& browser_field) {
  auto browser_version_obj = browser_field.get_object();
  if (browser_version_obj.has_value()) {
    return get_version_added_float_from_object(browser_version_obj.value());
  }

  // some browser compat values are arrays rather than objects (see: api > Performance > clearMeasures)
  simdjson::ondemand::array browser_version_arr = browser_field.get_array();
  float lowest_version_added = 9999.0f;
  for (auto obj : browser_version_arr) {
    browser_version_obj = obj.get_object();
    if (browser_version_obj.has_value()) {
      VersionAdded version_added = get_version_added_float_from_object(browser_version_obj.value());
      if (version_added.version) {
        if (version_added.version < lowest_version_added) {
          lowest_version_added = version_added.version;
        }
      }
    }
  }

  return {.version = lowest_version_added};
}

/// Recursively write a list of `features` to an `out` bin file
void write_feature_vec_to_bin_file(
  OutBinInfo&              out_bin_info,
  std::vector<CiuFeature>& features,
  CiuFeature*              parent_feature
) {
  auto out = out_bin_info.stream;
  bool has_first_child_been_written = false;
  for (auto& feature : features) {
    // global support %
    out->seekp(out_bin_info.section_pos[(int)BinSection::Support], std::ios_base::beg);
    out->write((char*)&feature.support, sizeof(float));
    out_bin_info.section_pos[(int)BinSection::Support] += SIZEOF_SUPPORT_SECTION_ENTRY;

    // identifier name
    out->seekp(out_bin_info.section_pos[(int)BinSection::Identifier], std::ios_base::beg);
    write_string_padded(*out, feature.identifier.data(), feature.identifier.size());
    out_bin_info.section_pos[(int)BinSection::Identifier] += SIZEOF_IDENTIFIER_SECTION_ENTRY;

    // tree-sitter syntax node type
    out->seekp(out_bin_info.section_pos[(int)BinSection::TreeSitterSyntaxNodeType], std::ios_base::beg);
    uint8_t type = (uint8_t)feature.type;
    out->write((char*)&type, sizeof(uint8_t));
    out_bin_info.section_pos[(int)BinSection::TreeSitterSyntaxNodeType] += sizeof(uint8_t);

    // # children
    size_t num_children = feature.children.size();
    out->seekp(out_bin_info.section_pos[(int)BinSection::NumChildren], std::ios_base::beg);
    out->write((char*)&num_children, sizeof(uint16_t));
    out_bin_info.section_pos[(int)BinSection::NumChildren] += sizeof(uint16_t);

    // first child index (I write this for my parent when I am the first child)
    if (parent_feature != nullptr && !has_first_child_been_written) {
      size_t parent_first_child_idx_seek_pos =
        out_bin_info.section_pos[(int)BinSection::FirstChildIndex]
        + (parent_feature->index_in_bin_file * sizeof(uint32_t));
      out->seekp(parent_first_child_idx_seek_pos, std::ios_base::beg);
      out->write((char*)&out_bin_info.num_features_so_far, sizeof(uint32_t));
      has_first_child_been_written = true;
    }

    // caniuse feature ID
    out->seekp(0, std::ios_base::end);
    uint32_t ciu_id_addr = out->tellp();
    uint8_t len_ciu_feature_id = feature.ciu_id.size();
    out->write((char*)&len_ciu_feature_id, 1);
    write_string(*out, feature.ciu_id.data(), len_ciu_feature_id);

    // address of the caniuse feature ID we just wrote
    out->seekp(out_bin_info.section_pos[(int)BinSection::CiuIdAddr], std::ios_base::beg);
    out->write((char*)&ciu_id_addr, sizeof(uint32_t));
    out_bin_info.section_pos[(int)BinSection::CiuIdAddr] += SIZEOF_CIU_ID_ADDRS_SECTION_ENTRY;

    // increment total feature index
    feature.index_in_bin_file = out_bin_info.num_features_so_far;
    out_bin_info.num_features_so_far++;
  }

  // now go through each feature's children and do the same for those, recursively
  for (auto& feature : features) {
    if (feature.children.size() > 0) {
      write_feature_vec_to_bin_file(
        out_bin_info,
        feature.children,
        &feature
      );
    }
  }
}

/// Write the feature tree generated from parsing the BCD JSON to the out bin files
void write_bin_files() {
  for (auto& pair : out_bins) {
    write_feature_vec_to_bin_file(
      pair.second,
      pair.second.features,
      nullptr
    );
  }
}

/// Write a null-terminated string to an output stream
void write_string(std::ofstream& out, const char* data, int len) {
  out.write(data, len);
}

/// Write a null-terminated string, that is then padded with 0's to fill a certain width, to an output stream
void write_string_padded(std::ofstream& out, char* data, int len) {
  out.write(data, len);
  if (len % STRING_PADDING_WIDTH != 0) {
    out.write(zeroes, STRING_PADDING_WIDTH - (len % STRING_PADDING_WIDTH));
  }
}
