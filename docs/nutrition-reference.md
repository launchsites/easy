# Offline food reference

Easy includes 138 generic foods from USDA FoodData Central, SR Legacy April 2018. The extract includes 2,057 nutrient rows and 474 published household measures. USDA dedicates FoodData Central data to the public domain under CC0 1.0. [FoodData Central data and license](https://fdc.nal.usda.gov/api-guide.html) · [Dataset archive](https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip)

The extract keeps the FDC food ID, NDB number, official description, nutrient row ID, published amount per 100 g, measurement unit, derivation code and data-point count where available. A published zero stays present and an absent row stays unknown. The user-facing log totals energy, protein, carbohydrate and fat using the composition snapshot saved with each meal portion. Other extracted nutrients remain available as reference data. [Source selection](../tool/nutrition/reference_sr_legacy_selection.tsv) · [Catalog implementation](../lib/nutrition/reference_food_catalog.dart)

The food picker searches personal saved foods and the local reference. A reference entry keeps its preparation in its name. Raw and cooked entries can have very different values per 100 g. Choose or weigh the portion separately. A published household measure fills an estimated weight and records its FDC portion ID. Typing a replacement weight clears the earlier estimate source and range. Previous meals keep their original composition and estimate snapshots. [Nutrition model](../lib/nutrition/nutrition_model.dart)

Photo review checks for an exact saved-food name first, then an exact reference name or curated alias. Broad labels such as rice can match multiple preparations. Tap a candidate to choose the food and enter or correct its amount. Select the results to apply them to the editable meal. The provider offers candidate labels and optional gram ranges. Easy calculates the selected totals from local food values. [Photo review](../lib/nutrition/meal_vision_review.dart)

## Reproduce the extract

Download the USDA archive above. The generator checks its SHA-256 against `b80817294b8850530aaedf2e515c02593b1824f763a0ff356e5c2081643e6fd0`, validates units and unique source rows, then verifies the checked-in Dart part byte for byte.

```sh
python3 tool/nutrition/generate_reference_sr_legacy.py FoodData_Central_sr_legacy_food_csv_2018-04.zip --check
flutter test test/nutrition_reference_test.dart test/nutrition_test.dart test/meal_vision_test.dart
```
