# Offline food reference

Easy includes 138 generic foods from USDA FoodData Central, SR Legacy April 2018. The extract includes 2,057 nutrient rows and 474 published household measures. USDA dedicates FoodData Central data to the public domain under CC0 1.0. [FoodData Central data and license](https://fdc.nal.usda.gov/api-guide.html) · [Dataset archive](https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip)

The extract keeps the FDC food ID, NDB number, official description, nutrient row ID, published amount per 100 g, measurement unit, derivation code and data-point count where available. A published zero stays present and an absent row stays unknown. Meals store the composition snapshot used to calculate their nutrition. [Source selection](../tool/nutrition/reference_sr_legacy_selection.tsv) · [Catalog implementation](../lib/nutrition/reference_food_catalog.dart)

The food picker searches personal saved foods and the local reference. A reference entry keeps its preparation in its name. Raw and cooked entries can have very different values per 100 g. Choose or weigh the portion separately. A published household measure fills an estimated weight and records its FDC portion ID. Typing a replacement weight clears the earlier estimate source and range. Previous meals keep their original composition and estimate snapshots. [Nutrition model](../lib/nutrition/nutrition_model.dart)

Photo review checks for an exact saved-food name first, then an exact reference name or curated alias. Broad labels such as rice can match multiple preparations. Tap a candidate to choose the food and enter or correct its amount. Select the results to apply them to the editable meal. The provider offers candidate labels and optional gram ranges. Easy calculates the selected totals from local food values. [Photo review](../lib/nutrition/meal_vision_review.dart)

## Saved meal recipes

Save an editable meal as a recipe or create a recipe from the library in Nutrition. Record the number of servings in the batch and, optionally, the measured finished batch weight. The two yield values are entered independently from ingredient quantities. Choose a saved recipe and enter the servings eaten, or choose finished weight if the recipe has that measurement. Easy scales each original ingredient and recorded range within its existing unit. Proportional shares are marked estimated.

The portion opens in the regular meal editor before logging. Saving or revising a recipe leaves earlier meals intact. A recipe keeps its ingredient and composition snapshots each time a new portion is prepared. [Recipe model](../lib/nutrition/nutrition_model.dart)

## Additional nutrients

Open **More nutrients** in Daily totals to see fibre, sugars, minerals and vitamins with their g, mg or µg units. A detail total requires a reported value from every portion. When some portions have values, the total shows how many were reported and keeps the full amount unknown. Complete totals carry measured amounts or the applicable estimate and range. Additional nutrient fields in saved food labels are optional and start empty. A previously saved meal keeps the nutrient fields available when it was logged. [Totals and snapshot validation](../lib/nutrition/nutrition_model.dart)

Packaged-food barcode coverage depends on the region and release. The USDA Branded Foods documentation currently lists United States and New Zealand market coverage. The offline catalogue here uses the published SR Legacy generic foods. [USDA Branded Foods market coverage](https://fdc.nal.usda.gov/GBFPD_Documentation/#market-country)

## Reproduce the extract

Download the USDA archive above. The generator checks its SHA-256 against `b80817294b8850530aaedf2e515c02593b1824f763a0ff356e5c2081643e6fd0`, validates units and unique source rows, then verifies the checked-in Dart part byte for byte.

```sh
python3 tool/nutrition/generate_reference_sr_legacy.py FoodData_Central_sr_legacy_food_csv_2018-04.zip --check
flutter test test/nutrition_reference_test.dart test/nutrition_detail_test.dart test/nutrition_recipes_test.dart test/nutrition_test.dart test/meal_vision_test.dart
```
